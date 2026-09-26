#!/bin/bash
# Set up the app ACL on each Sentinel-managed Redis node, then reuse the
# existing RediSearch index and MSSQL endpoint initialization.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
read_env() {
  sed -n "s/^$1=//p" "$SCRIPT_DIR/.env" 2>/dev/null | tail -n 1 | tr -d '\r'
}

REDIS_PASSWORD="${REDIS_PASSWORD:-$(read_env REDIS_PASSWORD)}"
REDIS_USER_PASSWORD="${REDIS_USER_PASSWORD:-$(read_env REDIS_USER_PASSWORD)}"
REDIS_USER="${REDIS_USER:-$(read_env REDIS_USER)}"
REDIS_KEY_PREFIX="${REDIS_KEY_PREFIX:-$(read_env REDIS_KEY_PREFIX)}"
REDIS_INDEX_NAME="${REDIS_INDEX_NAME:-$(read_env REDIS_INDEX_NAME)}"
: "${REDIS_PASSWORD:?REDIS_PASSWORD must be set in redis/.env}"
: "${REDIS_USER_PASSWORD:?REDIS_USER_PASSWORD must be set in redis/.env}"
REDIS_USER="${REDIS_USER:-agora_user}"
REDIS_KEY_PREFIX="${REDIS_KEY_PREFIX:-canvas:}"
REDIS_INDEX_NAME="${REDIS_INDEX_NAME:-idx:canvas}"

for container in agora-redis-primary agora-redis-replica-1 agora-redis-replica-2; do
  ready=false
  for attempt in {1..90}; do
    if "$SCRIPT_DIR/redis-container-cli.sh" "$container" admin ping 2>/dev/null | grep -q PONG; then
      ready=true
      break
    fi
    sleep 1
  done
  if [ "$ready" != true ]; then
    echo "Redis node did not become ready: $container" >&2
    exit 1
  fi

  echo "Configuring ACL on $container"
  "$SCRIPT_DIR/redis-container-cli.sh" "$container" provision-app
  "$SCRIPT_DIR/redis-container-cli.sh" "$container" admin ACL SAVE
done

for container in agora-redis-sentinel-1 agora-redis-sentinel-2 agora-redis-sentinel-3; do
  ready=false
  for attempt in {1..90}; do
    if [ "$(docker inspect -f '{{.State.Health.Status}}' "$container" 2>/dev/null || true)" = "healthy" ]; then
      ready=true
      break
    fi
    sleep 1
  done
  if [ "$ready" != true ]; then
    echo "Redis Sentinel did not become healthy: $container" >&2
    exit 1
  fi
done

"$SCRIPT_DIR/redis-ha-cli.sh" ping >/dev/null

# Creates the JSON search index through Sentinel and registers exactly one
# logical Redis HA service row with MSSQL.
bash "$SCRIPT_DIR/init-redis.sh"
