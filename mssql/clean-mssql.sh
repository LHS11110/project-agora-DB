#!/bin/bash
# ==============================================================================
# Agora MS SQL Data Cleanup Script
# MS SQL Server (agora_db) 전용 데이터 초기화 스크립트
# ==============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

FORCE_CONFIRM=false
RE_REGISTER_REDIS=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes|--force)
      FORCE_CONFIRM=true
      shift
      ;;
    --no-re-register)
      RE_REGISTER_REDIS=false
      shift
      ;;
    -h|--help)
      echo -e "${BOLD}사용법:${NC} $0 [옵션]"
      echo "  -y, --yes, --force   확인 프롬프트를 건너뛰고 즉시 삭제를 진행합니다"
      echo "  --no-re-register     Redis 서버(redis_server) 자동 재등록을 건너뜁니다"
      exit 0
      ;;
    *)
      shift
      ;;
  esac
done

if [ "$FORCE_CONFIRM" = false ]; then
  echo -e "${YELLOW}⚠️  [경고] MS SQL ($MSSQL_DB) 내 모든 테이블 데이터가 삭제됩니다.${NC}"
  read -r -p "정말로 삭제하시겠습니까? [y/N]: " USER_INPUT
  if [[ ! "$USER_INPUT" =~ ^[yY]([eE][sS])?$ ]]; then
    echo "작업이 취소되었습니다."
    exit 0
  fi
fi

# .env 로드
if [ -f "$SCRIPT_DIR/.env" ]; then
  ENV_FILE="$SCRIPT_DIR/.env"
elif [ -f "$ROOT_DIR/mssql/.env" ]; then
  ENV_FILE="$ROOT_DIR/mssql/.env"
else
  ENV_FILE=""
fi

if [ -n "$ENV_FILE" ]; then
  MSSQL_RAW_HOST=$(grep -v '^#' "$ENV_FILE" | grep 'MSSQL_EXTERNAL_IP=' | cut -d '=' -f2- | tr -d '\r' || true)
  if [ -z "$MSSQL_RAW_HOST" ]; then
    MSSQL_RAW_HOST=$(grep -v '^#' "$ENV_FILE" | grep 'MSSQL_HOST=' | cut -d '=' -f2- | tr -d '\r' || echo "127.0.0.1")
  fi
  MSSQL_HOST="127.0.0.1"
  if [ "$MSSQL_RAW_HOST" != "0.0.0.0" ] && [ -n "$MSSQL_RAW_HOST" ]; then
    MSSQL_HOST="$MSSQL_RAW_HOST"
  fi
  MSSQL_PORT=$(grep -v '^#' "$ENV_FILE" | grep 'MSSQL_EXTERNAL_PORT=' | cut -d '=' -f2- | tr -d '\r' || true)
  if [ -z "$MSSQL_PORT" ]; then
    MSSQL_PORT=$(grep -v '^#' "$ENV_FILE" | grep 'MSSQL_PORT=' | cut -d '=' -f2- | tr -d '\r' || echo "1433")
  fi
  MSSQL_DB=$(grep -v '^#' "$ENV_FILE" | grep 'MSSQL_DB=' | cut -d '=' -f2- | tr -d '\r' || echo "agora_db")
  MSSQL_USER=$(grep -v '^#' "$ENV_FILE" | grep 'MSSQL_USER=' | cut -d '=' -f2- | tr -d '\r' || echo "agora_user")
  MSSQL_PASS=$(grep -v '^#' "$ENV_FILE" | grep 'MSSQL_PASSWORD=' | cut -d '=' -f2- | tr -d '\r' || echo "")
  MSSQL_TABLE_USERS=$(grep -v '^#' "$ENV_FILE" | grep 'MSSQL_TABLE_USERS=' | cut -d '=' -f2- | tr -d '\r' || echo "users")
  MSSQL_TABLE_REDIS_SERVER=$(grep -v '^#' "$ENV_FILE" | grep 'MSSQL_TABLE_REDIS_SERVER=' | cut -d '=' -f2- | tr -d '\r' || echo "redis_server")
  MSSQL_TABLE_CANVAS_INFO=$(grep -v '^#' "$ENV_FILE" | grep 'MSSQL_TABLE_CANVAS_INFO=' | cut -d '=' -f2- | tr -d '\r' || echo "canvas_info")
  MSSQL_TABLE_CPP_SERVER=$(grep -v '^#' "$ENV_FILE" | grep 'MSSQL_TABLE_CPP_SERVER=' | cut -d '=' -f2- | tr -d '\r' || echo "cpp_server")
else
  MSSQL_HOST="127.0.0.1"
  MSSQL_PORT="1433"
  MSSQL_DB="agora_db"
  MSSQL_USER="agora_user"
  MSSQL_PASS=""
  MSSQL_TABLE_USERS="users"
  MSSQL_TABLE_REDIS_SERVER="redis_server"
  MSSQL_TABLE_CANVAS_INFO="canvas_info"
  MSSQL_TABLE_CPP_SERVER="cpp_server"
fi

echo -e "${YELLOW}MS SQL Server 데이터 삭제 중... ($MSSQL_USER@$MSSQL_HOST:$MSSQL_PORT/$MSSQL_DB)${NC}"

run_mssql_cmd() {
  local query="$1"
  if command -v sqlcmd &> /dev/null; then
    sqlcmd -S "$MSSQL_HOST,$MSSQL_PORT" -U "$MSSQL_USER" -P "$MSSQL_PASS" -C -I -d "$MSSQL_DB" -Q "$query" -W -h -1 2>&1
  else
    docker exec agora-mssql /opt/mssql-tools18/bin/sqlcmd \
      -S localhost -U "$MSSQL_USER" -P "$MSSQL_PASS" -C -I -d "$MSSQL_DB" -W -h -1 -Q "$query" 2>&1
  fi
}

COUNT_QUERY="SET NOCOUNT ON;
SELECT
  (SELECT COUNT(*) FROM [$MSSQL_TABLE_USERS]) AS cnt_users,
  (SELECT COUNT(*) FROM [user_sessions]) AS cnt_sessions,
  (SELECT COUNT(*) FROM [$MSSQL_TABLE_CANVAS_INFO]) AS cnt_canvas,
  (SELECT COUNT(*) FROM [$MSSQL_TABLE_REDIS_SERVER]) AS cnt_redis,
  (SELECT COUNT(*) FROM [$MSSQL_TABLE_CPP_SERVER]) AS cnt_cpp;
"

BEFORE_COUNTS=$(run_mssql_cmd "$COUNT_QUERY" | tr -s '[:space:]' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
echo "  - 삭제 전 레코드 수: $BEFORE_COUNTS (users, user_sessions, canvas_info, redis_server, cpp_server)"

DELETE_QUERY="SET NOCOUNT ON;
BEGIN TRANSACTION;
  DELETE FROM [user_sessions];
  DELETE FROM [$MSSQL_TABLE_CANVAS_INFO];
  DELETE FROM [$MSSQL_TABLE_USERS];
  DELETE FROM [$MSSQL_TABLE_CPP_SERVER];
  DELETE FROM [$MSSQL_TABLE_REDIS_SERVER];

  IF OBJECT_ID('$MSSQL_TABLE_USERS', 'U') IS NOT NULL DBCC CHECKIDENT ('[$MSSQL_TABLE_USERS]', RESEED, 0);
  IF OBJECT_ID('$MSSQL_TABLE_CANVAS_INFO', 'U') IS NOT NULL DBCC CHECKIDENT ('[$MSSQL_TABLE_CANVAS_INFO]', RESEED, 0);
  IF OBJECT_ID('$MSSQL_TABLE_CPP_SERVER', 'U') IS NOT NULL DBCC CHECKIDENT ('[$MSSQL_TABLE_CPP_SERVER]', RESEED, 0);
  IF OBJECT_ID('$MSSQL_TABLE_REDIS_SERVER', 'U') IS NOT NULL DBCC CHECKIDENT ('[$MSSQL_TABLE_REDIS_SERVER]', RESEED, 0);
COMMIT TRANSACTION;
"

run_mssql_cmd "$DELETE_QUERY" > /dev/null

if [ "$RE_REGISTER_REDIS" = true ]; then
  if [ -f "$ROOT_DIR/redis/register-to-mssql.sh" ]; then
    echo "  - Redis 인스턴스 엔드포인트 자동 재등록 중..."
    bash "$ROOT_DIR/redis/register-to-mssql.sh" > /dev/null 2>&1
    echo "  - [OK] Redis 서버 인스턴스 자동 재등록 완료"
  fi
fi

AFTER_COUNTS=$(run_mssql_cmd "$COUNT_QUERY" | tr -s '[:space:]' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
echo -e "  [${GREEN}OK${NC}] MS SQL 테이블 데이터 삭제 완료 (삭제 후 상태: $AFTER_COUNTS)\n"
