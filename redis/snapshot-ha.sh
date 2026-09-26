#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$ENV_FILE"
  set +a
fi
: "${REDIS_PASSWORD:?REDIS_PASSWORD is required}"
OUT_FILE="${1:-$SCRIPT_DIR/backups/agora-redis-$(date -u +%Y%m%dT%H%M%SZ).rdb}"
mkdir -p "$(dirname "$OUT_FILE")"
chmod 700 "$(dirname "$OUT_FILE")"
TEMP_FILE="/tmp/agora-redis-backup-$$.rdb"
SOURCE_CONTAINER=""

for candidate in agora-redis-primary agora-redis-replica-1 agora-redis-replica-2 agora-redis-node; do
  if [ "$(docker inspect -f '{{.State.Running}}' "$candidate" 2>/dev/null || true)" != "true" ]; then continue; fi
  role=$("$SCRIPT_DIR/redis-container-cli.sh" "$candidate" admin --raw INFO replication 2>/dev/null \
    | sed -n 's/^role://p' | tr -d '\r')
  if [ "$role" = "master" ]; then SOURCE_CONTAINER="$candidate"; break; fi
done

if [ -z "$SOURCE_CONTAINER" ]; then
  echo "No running Redis Sentinel primary was found." >&2
  exit 1
fi

"$SCRIPT_DIR/redis-container-cli.sh" "$SOURCE_CONTAINER" admin --rdb "$TEMP_FILE"

docker exec "$SOURCE_CONTAINER" redis-check-rdb "$TEMP_FILE" >/dev/null
docker cp "$SOURCE_CONTAINER:$TEMP_FILE" "$OUT_FILE"
docker exec "$SOURCE_CONTAINER" rm -f "$TEMP_FILE"
chmod 600 "$OUT_FILE"
echo "Redis RDB snapshot verified: $OUT_FILE"
