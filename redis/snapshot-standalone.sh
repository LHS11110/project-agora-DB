#!/bin/bash
# Save the current standalone Redis dataset for the Sentinel HA migration.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
  echo "Redis environment file not found: $ENV_FILE" >&2
  exit 1
fi

REDIS_ADMIN_PASS=$(sed -n 's/^REDIS_PASSWORD=//p' "$ENV_FILE" | tail -n 1 | tr -d '\r')
: "${REDIS_ADMIN_PASS:?REDIS_PASSWORD must be set in redis/.env}"
SNAPSHOT_PATH="${1:-/tmp/agora-redis-dump.rdb}"

docker exec -e REDISCLI_AUTH="$REDIS_ADMIN_PASS" agora-redis-stack redis-cli SAVE
docker cp agora-redis-stack:/data/dump.rdb "$SNAPSHOT_PATH"
chmod 600 "$SNAPSHOT_PATH"
echo "Redis snapshot saved to $SNAPSHOT_PATH"
