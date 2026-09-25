#!/bin/bash
# Execute a Redis command on whichever node Sentinel currently considers the
# primary. This is for the repository's host-side maintenance tools.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  echo "Redis environment file not found: $ENV_FILE" >&2
  exit 1
fi

read_env() {
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1 | tr -d '\r'
}

REDIS_ADMIN_PASS="$(read_env REDIS_PASSWORD)"
: "${REDIS_ADMIN_PASS:?REDIS_PASSWORD must be set in redis/.env}"
REDIS_SENTINEL_USER="$(read_env REDIS_SENTINEL_USER)"
REDIS_SENTINEL_PASS="$(read_env REDIS_SENTINEL_PASSWORD)"
if [ -n "$REDIS_SENTINEL_USER" ] && [ -z "$REDIS_SENTINEL_PASS" ] || [ -z "$REDIS_SENTINEL_USER" ] && [ -n "$REDIS_SENTINEL_PASS" ]; then
  echo "REDIS_SENTINEL_USER and REDIS_SENTINEL_PASSWORD must be set together." >&2
  exit 1
fi
SENTINEL_AUTH_ARGS=()
if [ -n "$REDIS_SENTINEL_PASS" ]; then
  SENTINEL_AUTH_ARGS=(--user "$REDIS_SENTINEL_USER")
fi

for container in agora-redis-primary agora-redis-replica-1 agora-redis-replica-2; do
  if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)" != "true" ]; then
    continue
  fi

  role=$(docker exec -e REDISCLI_AUTH="$REDIS_ADMIN_PASS" "$container" \
    redis-cli --raw INFO replication 2>/dev/null | sed -n 's/^role://p' | tr -d '\r')
  if [ "$role" = "master" ]; then
    exec docker exec -e REDISCLI_AUTH="$REDIS_ADMIN_PASS" "$container" redis-cli "$@"
  fi
done

if [ "$(docker inspect -f '{{.State.Running}}' agora-redis-node 2>/dev/null || true)" = "true" ] \
  && [ "$(docker inspect -f '{{.State.Running}}' agora-redis-sentinel 2>/dev/null || true)" = "true" ]; then
  master_info=$(docker exec -e REDISCLI_AUTH="$REDIS_SENTINEL_PASS" agora-redis-sentinel redis-cli -p 26379 --raw \
    "${SENTINEL_AUTH_ARGS[@]}" SENTINEL get-master-addr-by-name agora-master)
  master_host=$(printf '%s\n' "$master_info" | sed -n '1p')
  master_port=$(printf '%s\n' "$master_info" | sed -n '2p')
  if [ -n "$master_host" ] && [ -n "$master_port" ]; then
    exec docker exec -e REDISCLI_AUTH="$REDIS_ADMIN_PASS" agora-redis-node \
      redis-cli -h "$master_host" -p "$master_port" "$@"
  fi
fi

echo "No running Redis primary found among the Sentinel-managed nodes." >&2
exit 1
