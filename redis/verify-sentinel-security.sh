#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
SENTINELS=(agora-redis-sentinel-1 agora-redis-sentinel-2 agora-redis-sentinel-3)

read_env() {
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1 | tr -d '\r'
}

[ -f "$ENV_FILE" ] || { echo "Redis environment file is missing." >&2; exit 1; }
EXPECTED_USER="$(read_env REDIS_SENTINEL_USER)"
EXPECTED_PASSWORD="$(read_env REDIS_SENTINEL_PASSWORD)"
TLS_ENABLED="$(read_env REDIS_TLS_ENABLED)"
: "${EXPECTED_USER:?REDIS_SENTINEL_USER must be set in redis/.env}"
: "${EXPECTED_PASSWORD:?REDIS_SENTINEL_PASSWORD must be set in redis/.env}"
[ "$TLS_ENABLED" = true ] || { echo "Redis/Sentinel TLS is not enabled." >&2; exit 1; }

EXPECTED_MASTER=""
for sentinel in "${SENTINELS[@]}"; do
  if [ "$(docker inspect -f '{{.State.Running}}' "$sentinel" 2>/dev/null || true)" != true ]; then
    echo "Sentinel is not running: $sentinel" >&2
    exit 1
  fi

  actual_user="$(docker exec "$sentinel" sh -c 'printf %s "$REDIS_SENTINEL_USER"')"
  if [ "$actual_user" != "$EXPECTED_USER" ]; then
    echo "Dedicated Sentinel reader username is missing or mismatched: $sentinel" >&2
    exit 1
  fi
  if ! docker exec "$sentinel" sh -c \
    '[ -n "$REDIS_SENTINEL_PASSWORD" ] && [ "$REDIS_SENTINEL_PASSWORD" != "$REDIS_PASSWORD" ]'; then
    echo "Sentinel must use a separate non-empty reader password: $sentinel" >&2
    exit 1
  fi

  acl="$("$SCRIPT_DIR/redis-container-cli.sh" "$sentinel" sentinel-admin --raw ACL GETUSER "$EXPECTED_USER")"
  commands="$(printf '%s\n' "$acl" | sed -n '/^commands$/{n;p;}')"
  [[ "$commands" == *"+sentinel|get-master-addr-by-name"* ]] || {
    echo "Reader ACL cannot query Sentinel topology: $sentinel" >&2
    exit 1
  }
  [[ "$commands" != *"+@all"* && "$commands" != *"+sentinel|failover"* ]] || {
    echo "Sentinel reader ACL grants an administrative command: $sentinel" >&2
    exit 1
  }

  master="$("$SCRIPT_DIR/redis-container-cli.sh" "$sentinel" sentinel --raw \
    SENTINEL get-master-addr-by-name "$(read_env REDIS_SENTINEL_MASTER_NAME)")"
  if [ -z "$EXPECTED_MASTER" ]; then
    EXPECTED_MASTER="$master"
  elif [ "$master" != "$EXPECTED_MASTER" ]; then
    echo "Sentinels disagree on the current primary." >&2
    exit 1
  fi
done

echo "All three Sentinels have the dedicated read-only account and agree on the current primary."
echo "Redis TLS is enabled for Sentinel queries."
