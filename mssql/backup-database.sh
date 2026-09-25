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

docker exec -u 0 agora-mssql mkdir -p /var/opt/mssql/backup
docker exec -u 0 agora-mssql chown mssql:mssql /var/opt/mssql/backup
docker exec agora-mssql /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -b -I \
  -Q "IF DB_ID(N'$DATABASE') IS NULL THROW 51000, 'Database not found', 1; IF sys.fn_hadr_is_primary_replica(N'$DATABASE') = 0 THROW 51001, 'Run backup on the AG primary', 1; BACKUP DATABASE [$DATABASE] TO DISK = N'$CONTAINER_PATH' WITH COMPRESSION, CHECKSUM, INIT; RESTORE VERIFYONLY FROM DISK = N'$CONTAINER_PATH' WITH CHECKSUM;"
docker cp "agora-mssql:$CONTAINER_PATH" "$BACKUP_DIR/$BACKUP_NAME"
chmod 600 "$BACKUP_DIR/$BACKUP_NAME"
echo "SQL backup and VERIFYONLY completed: $BACKUP_DIR/$BACKUP_NAME"
