#!/usr/bin/env bash
set -euo pipefail

if [ "${ALLOW_REDIS_RESTORE:-false}" != "true" ]; then
  echo "Set ALLOW_REDIS_RESTORE=true only for an empty recovery target." >&2
  exit 2
fi
BACKUP_FILE="${1:?Usage: ALLOW_REDIS_RESTORE=true $0 /path/to/dump.rdb [container]}"
CONTAINER="${2:-agora-redis-stack}"
if [ ! -f "$BACKUP_FILE" ]; then
  echo "RDB file not found: $BACKUP_FILE" >&2
  exit 2
fi
if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" = "true" ]; then
  echo "Stop the empty recovery Redis container before placing dump.rdb." >&2
  exit 2
fi
docker cp "$BACKUP_FILE" "$CONTAINER:/data/dump.rdb"
docker start "$CONTAINER" >/dev/null
echo "RDB placed in $CONTAINER. Verify JSON and search access, then test BE reconnect before routing traffic."
