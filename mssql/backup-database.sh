#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi
: "${MSSQL_SA_PASSWORD:?MSSQL_SA_PASSWORD is required}"
DATABASE="${MSSQL_DB:-agora_db}"
if [[ ! "$DATABASE" =~ ^[A-Za-z0-9_]+$ ]]; then
  echo "MSSQL_DB may contain only letters, digits, and underscores for backup tooling." >&2
  exit 2
fi
BACKUP_DIR="${1:-$SCRIPT_DIR/backups}"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
BACKUP_NAME="${DATABASE}-$(date -u +%Y%m%dT%H%M%SZ).bak"
CONTAINER_PATH="/var/opt/mssql/backup/$BACKUP_NAME"

CONTAINER="${MSSQL_CONTAINER:-}"
if [ -z "$CONTAINER" ]; then
  if [ "$(docker inspect -f '{{.State.Running}}' agora-mssql 2>/dev/null || true)" = "true" ]; then
    CONTAINER=agora-mssql
  else
    mapfile -t AG_NODE_CONTAINERS < <(docker ps -q --filter label=com.docker.compose.service=mssql-ag-node)
    if [ "${#AG_NODE_CONTAINERS[@]}" -eq 1 ]; then
      CONTAINER="${AG_NODE_CONTAINERS[0]}"
    else
      echo "Set MSSQL_CONTAINER or run exactly one SQL AG node container on this host." >&2
      exit 1
    fi
  fi
fi
if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || true)" != "true" ]; then
  echo "SQL Server container is not running: $CONTAINER" >&2
  exit 1
fi
cleanup_container_backup() {
  docker exec "$CONTAINER" rm -f "$CONTAINER_PATH" >/dev/null 2>&1 || true
}
trap cleanup_container_backup EXIT

docker exec -u 0 "$CONTAINER" mkdir -p /var/opt/mssql/backup
docker exec -u 0 "$CONTAINER" chown mssql:mssql /var/opt/mssql/backup
docker exec "$CONTAINER" /bin/bash -lc \
  'export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"; exec /opt/mssql-tools18/bin/sqlcmd "$@"' \
  sqlcmd -S localhost -U sa -C -b -I \
  -Q "IF DB_ID(N'$DATABASE') IS NULL THROW 51000, 'Database not found', 1; IF sys.fn_hadr_is_primary_replica(N'$DATABASE') = 0 THROW 51001, 'Run backup on the AG primary', 1; BACKUP DATABASE [$DATABASE] TO DISK = N'$CONTAINER_PATH' WITH CHECKSUM, INIT; RESTORE VERIFYONLY FROM DISK = N'$CONTAINER_PATH' WITH CHECKSUM;"
docker cp "$CONTAINER:$CONTAINER_PATH" "$BACKUP_DIR/$BACKUP_NAME"
chmod 600 "$BACKUP_DIR/$BACKUP_NAME"
echo "SQL backup and VERIFYONLY completed from $CONTAINER: $BACKUP_DIR/$BACKUP_NAME"
