#!/usr/bin/env bash
set -euo pipefail

if [ "${ALLOW_MSSQL_RESTORE:-false}" != "true" ]; then
  echo "Set ALLOW_MSSQL_RESTORE=true only for a new recovery target." >&2
  exit 2
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi
: "${MSSQL_SA_PASSWORD:?MSSQL_SA_PASSWORD is required}"
BACKUP_FILE="${1:?Usage: ALLOW_MSSQL_RESTORE=true $0 /path/to/database.bak}"
if [ ! -f "$BACKUP_FILE" ]; then
  echo "Backup file not found: $BACKUP_FILE" >&2
  exit 2
fi
DATABASE="${MSSQL_DB:-agora_db}"
if [[ ! "$DATABASE" =~ ^[A-Za-z0-9_]+$ ]]; then
  echo "MSSQL_DB may contain only letters, digits, and underscores for restore tooling." >&2
  exit 2
fi
CONTAINER="${MSSQL_RESTORE_CONTAINER:-agora-mssql}"
CONTAINER_PATH="/var/opt/mssql/backup/restore-${DATABASE}.bak"
docker exec -u 0 "$CONTAINER" mkdir -p /var/opt/mssql/backup
docker cp "$BACKUP_FILE" "$CONTAINER:$CONTAINER_PATH"
docker exec -u 0 "$CONTAINER" chown mssql:mssql "$CONTAINER_PATH"
docker exec "$CONTAINER" /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -b -I \
  -Q "RESTORE VERIFYONLY FROM DISK = N'$CONTAINER_PATH' WITH CHECKSUM; IF DB_ID(N'$DATABASE') IS NOT NULL THROW 51002, 'Target database already exists; restore script will not overwrite it', 1; RESTORE DATABASE [$DATABASE] FROM DISK = N'$CONTAINER_PATH' WITH CHECKSUM, RECOVERY;"
echo "SQL restore completed to container $CONTAINER. Run mssql/init-mssql.sh against this target to recreate the runtime login, then verify BE access."
