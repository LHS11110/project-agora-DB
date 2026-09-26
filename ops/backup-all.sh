#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_ROOT="${AGORA_BACKUP_ROOT:-}"
if [ -z "$BACKUP_ROOT" ] || [ ! -d "$BACKUP_ROOT" ] || ! mountpoint -q "$BACKUP_ROOT"; then
  echo "AGORA_BACKUP_ROOT must be an existing mounted durable-storage path." >&2
  exit 2
fi
BACKUP_ROOT="$(realpath -e "$BACKUP_ROOT")"

set -a
# shellcheck disable=SC1091
source "$ROOT_DIR/elasticsearch/.env"
set +a
ES_SNAPSHOT_DIR="${ES_SNAPSHOT_HOST_DIR:-$ROOT_DIR/elasticsearch/snapshots}"
case "$ES_SNAPSHOT_DIR" in
  /*) ;;
  *) ES_SNAPSHOT_DIR="$ROOT_DIR/elasticsearch/$ES_SNAPSHOT_DIR" ;;
esac
ES_SNAPSHOT_DIR="$(realpath -m "$ES_SNAPSHOT_DIR")"
case "$ES_SNAPSHOT_DIR" in
  "$BACKUP_ROOT"|"$BACKUP_ROOT"/*) ;;
  *) echo "ES_SNAPSHOT_HOST_DIR must be inside AGORA_BACKUP_ROOT so ES snapshots reach durable storage." >&2; exit 2 ;;
esac

LOCK_FILE="$BACKUP_ROOT/.agora-db-backup.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Another Project Agora DB backup is already running." >&2
  exit 1
fi

RUN_DIR="$(mktemp -d "$BACKUP_ROOT/agora-db-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
chmod 700 "$RUN_DIR"
mkdir -m 700 "$RUN_DIR/sql" "$RUN_DIR/redis"
MANIFEST="$RUN_DIR/manifest.txt"
{
  printf 'started_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'host=%s\n' "$(hostname -f 2>/dev/null || hostname)"
} > "$MANIFEST"

"$ROOT_DIR/mssql/backup-database.sh" "$RUN_DIR/sql" >> "$MANIFEST"
"$ROOT_DIR/redis/snapshot-ha.sh" "$RUN_DIR/redis/redis-ha.rdb" >> "$MANIFEST"
"$ROOT_DIR/elasticsearch/snapshot-elasticsearch.sh" >> "$MANIFEST"
printf 'completed_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$MANIFEST"
chmod 600 "$MANIFEST"

echo "SQL backup, verified Redis RDB, and Elasticsearch snapshot completed. Run directory: $RUN_DIR"
