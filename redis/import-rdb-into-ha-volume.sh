#!/usr/bin/env bash
# Safely seed a stopped, newly-created Redis HA node's named volume from an RDB.
set -Eeuo pipefail

SNAPSHOT="${1:?Usage: $0 /path/to/snapshot.rdb [stopped-redis-container]}"
TARGET_CONTAINER="${2:-agora-redis-primary}"

if [ ! -f "$SNAPSHOT" ] || [ ! -s "$SNAPSHOT" ]; then
  echo "Snapshot file not found or empty: $SNAPSHOT" >&2
  exit 2
fi
SNAPSHOT="$(realpath "$SNAPSHOT")"

if ! docker inspect "$TARGET_CONTAINER" >/dev/null 2>&1; then
  echo "Create the target Redis container before importing its data: $TARGET_CONTAINER" >&2
  exit 2
fi
if [ "$(docker inspect -f '{{.State.Running}}' "$TARGET_CONTAINER")" = true ]; then
  echo "Stop the target Redis container before importing its data: $TARGET_CONTAINER" >&2
  exit 2
fi

DATA_VOLUME="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}' "$TARGET_CONTAINER")"
IMAGE="$(docker inspect -f '{{.Config.Image}}' "$TARGET_CONTAINER")"
if [ -z "$DATA_VOLUME" ] || [ -z "$IMAGE" ]; then
  echo "The target container must use a named /data volume and a Redis image." >&2
  exit 2
fi

docker run --rm --entrypoint /bin/sh \
  -v "$DATA_VOLUME:/data" \
  -v "$SNAPSHOT:/restore/dump.rdb:ro" \
  "$IMAGE" -c '
    set -eu
    redis-check-rdb /restore/dump.rdb >/dev/null
    if [ -n "$(find /data -mindepth 1 -maxdepth 1 -print -quit)" ]; then
      echo "Target /data volume is not empty; refusing to replace existing Redis data." >&2
      exit 2
    fi
    cp /restore/dump.rdb /data/dump.rdb
    chown redis:redis /data/dump.rdb
    chmod 600 /data/dump.rdb
    redis-check-rdb /data/dump.rdb >/dev/null
  '

echo "RDB imported into $DATA_VOLUME. Start the node once with REDIS_NODE_APPENDONLY=no, verify the data, stop it, then restart with REDIS_NODE_APPENDONLY=yes to enable AOF safely."
