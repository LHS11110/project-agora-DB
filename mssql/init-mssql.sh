#!/bin/bash
# ==============================================================================
# Agora MS SQL Server Database & User Initialization Script
# .env 설정을 기반으로 사용자 계정 생성, 소유 데이터베이스 생성 및 테이블 초기화
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_TRUST_CERT_OVERRIDE="${DB_TRUST_SERVER_CERTIFICATE:-}"

# .env 파일이 있으면 로드
if [ -f "$SCRIPT_DIR/.env" ]; then
  export $(grep -v '^#' "$SCRIPT_DIR/.env" | xargs)
elif [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

if [ -n "$DB_TRUST_CERT_OVERRIDE" ]; then
  DB_TRUST_SERVER_CERTIFICATE="$DB_TRUST_CERT_OVERRIDE"
fi

MSSQL_RAW_HOST="${MSSQL_EXTERNAL_IP:-${MSSQL_HOST:-127.0.0.1}}"
if [ "$MSSQL_RAW_HOST" = "0.0.0.0" ]; then
  MSSQL_HOST="127.0.0.1"
else
  MSSQL_HOST="$MSSQL_RAW_HOST"
fi
MSSQL_PORT="${MSSQL_EXTERNAL_PORT:-${MSSQL_PORT:-1433}}"
: "${MSSQL_SA_PASSWORD:?MSSQL_SA_PASSWORD must be set in mssql/.env}"
MSSQL_SA_PASS="$MSSQL_SA_PASSWORD"
MSSQL_DB="${MSSQL_DB:-agora_db}"
MSSQL_USER="${MSSQL_USER:-agora_user}"
: "${MSSQL_PASSWORD:?MSSQL_PASSWORD must be set in mssql/.env}"
MSSQL_PASS="$MSSQL_PASSWORD"
SQLCMD_TRUST_ARGS=()
if [ "${DB_TRUST_SERVER_CERTIFICATE:-false}" = "true" ]; then
  SQLCMD_TRUST_ARGS=(-C)
fi
MSSQL_TABLE_USERS="${MSSQL_TABLE_USERS:-users}"
MSSQL_TABLE_REDIS_SERVER="${MSSQL_TABLE_REDIS_SERVER:-redis_server}"
MSSQL_TABLE_CPP_SERVER="${MSSQL_TABLE_CPP_SERVER:-cpp_server}"
MSSQL_TABLE_CANVAS_INFO="${MSSQL_TABLE_CANVAS_INFO:-${MSSQL_TABLE_CANVAS_CACHE:-canvas_info}}"

SQL_FILE="$SCRIPT_DIR/init-mssql.sql"

if [ ! -f "$SQL_FILE" ]; then
  echo "[ERROR] 초기화 SQL 파일을 찾을 수 없습니다: $SQL_FILE"
  exit 1
fi

echo "=== 1. MS SQL 초기화 시작 ==="
echo "대상 호스트:   $MSSQL_HOST:$MSSQL_PORT"
echo "데이터베이스:  $MSSQL_DB"
echo "런타임 계정:   $MSSQL_USER"
echo "테이블 구성:   $MSSQL_TABLE_USERS, $MSSQL_TABLE_REDIS_SERVER, $MSSQL_TABLE_CANVAS_INFO, $MSSQL_TABLE_CPP_SERVER"

# 로컬 sqlcmd가 있으면 로컬 사용, 없으면 docker exec fallback 사용
if command -v sqlcmd &> /dev/null; then
  echo "로컬 sqlcmd를 사용하여 초기화합니다..."
  sqlcmd -S "$MSSQL_HOST,$MSSQL_PORT" -U sa -P "$MSSQL_SA_PASS" "${SQLCMD_TRUST_ARGS[@]}" -b -I \
    -v DB_NAME="$MSSQL_DB" DB_USER="$MSSQL_USER" DB_PASSWORD="$MSSQL_PASS" \
       TABLE_USERS="$MSSQL_TABLE_USERS" TABLE_REDIS_SERVER="$MSSQL_TABLE_REDIS_SERVER" \
       TABLE_CANVAS_INFO="$MSSQL_TABLE_CANVAS_INFO" TABLE_CANVAS_CACHE="$MSSQL_TABLE_CANVAS_INFO" \
       TABLE_CPP_SERVER="$MSSQL_TABLE_CPP_SERVER" \
    -i "$SQL_FILE"
else
  echo "Docker 컨테이너(agora-mssql) 내부 sqlcmd를 사용하여 초기화합니다..."
  docker exec -i agora-mssql /opt/mssql-tools18/bin/sqlcmd \
    -S localhost -U sa -P "$MSSQL_SA_PASS" "${SQLCMD_TRUST_ARGS[@]}" -b -I \
    -v DB_NAME="$MSSQL_DB" DB_USER="$MSSQL_USER" DB_PASSWORD="$MSSQL_PASS" \
       TABLE_USERS="$MSSQL_TABLE_USERS" TABLE_REDIS_SERVER="$MSSQL_TABLE_REDIS_SERVER" \
       TABLE_CANVAS_INFO="$MSSQL_TABLE_CANVAS_INFO" TABLE_CANVAS_CACHE="$MSSQL_TABLE_CANVAS_INFO" \
       TABLE_CPP_SERVER="$MSSQL_TABLE_CPP_SERVER" \
    < "$SQL_FILE"
fi

echo -e "\n=== 2. 런타임 사용자($MSSQL_USER) 최소 권한 및 접속 검증 ==="
if command -v sqlcmd &> /dev/null; then
  sqlcmd -S "$MSSQL_HOST,$MSSQL_PORT" -U "$MSSQL_USER" -P "$MSSQL_PASS" "${SQLCMD_TRUST_ARGS[@]}" -b -d "$MSSQL_DB" \
    -Q "SELECT DB_NAME() AS [database], USER_NAME() AS [db_role], SUSER_SNAME() AS [login_user], IS_ROLEMEMBER('agora_runtime') AS [is_runtime_member], IS_ROLEMEMBER('db_owner') AS [is_db_owner];"
else
  docker exec agora-mssql /opt/mssql-tools18/bin/sqlcmd \
    -S localhost -U "$MSSQL_USER" -P "$MSSQL_PASS" "${SQLCMD_TRUST_ARGS[@]}" -b -d "$MSSQL_DB" \
    -Q "SELECT DB_NAME() AS [database], USER_NAME() AS [db_role], SUSER_SNAME() AS [login_user], IS_ROLEMEMBER('agora_runtime') AS [is_runtime_member], IS_ROLEMEMBER('db_owner') AS [is_db_owner];"
fi

echo -e "\n[SUCCESS] MS SQL 데이터베이스($MSSQL_DB) 및 런타임 계정($MSSQL_USER) 초기화가 완료되었습니다."
