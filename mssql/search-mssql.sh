#!/bin/bash
# ==============================================================================
# Agora MS SQL Data Inspection & Search Script
# MS SQL Server (agora_db)에 저장된 테이블 및 데이터 조회/검색 스크립트
# ==============================================================================

set -e

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MSSQL_HOST_OVERRIDE="${MSSQL_TEST_HOST:-${DB_HOST:-${MSSQL_HOST:-}}}"
MSSQL_PORT_OVERRIDE="${MSSQL_TEST_PORT:-${DB_PORT:-${MSSQL_PORT:-}}}"
DB_ENCRYPT_OVERRIDE="${DB_ENCRYPT:-}"
DB_TRUST_CERT_OVERRIDE="${DB_TRUST_SERVER_CERTIFICATE:-}"

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
  DB_TRUST_SERVER_CERTIFICATE=$(grep -v '^#' "$ENV_FILE" | grep '^DB_TRUST_SERVER_CERTIFICATE=' | cut -d '=' -f2- | tr -d '\r' || true)
  DB_ENCRYPT=$(grep -v '^#' "$ENV_FILE" | grep '^DB_ENCRYPT=' | cut -d '=' -f2- | tr -d '\r' || true)
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
  DB_TRUST_SERVER_CERTIFICATE="false"
  DB_ENCRYPT="true"
  MSSQL_TABLE_USERS="users"
  MSSQL_TABLE_REDIS_SERVER="redis_server"
  MSSQL_TABLE_CANVAS_INFO="canvas_info"
  MSSQL_TABLE_CPP_SERVER="cpp_server"
fi

if [ -n "$MSSQL_HOST_OVERRIDE" ]; then
  MSSQL_HOST="$MSSQL_HOST_OVERRIDE"
  if [ "$MSSQL_HOST" = "0.0.0.0" ]; then MSSQL_HOST="127.0.0.1"; fi
fi
if [ -n "$MSSQL_PORT_OVERRIDE" ]; then MSSQL_PORT="$MSSQL_PORT_OVERRIDE"; fi
if [ -n "$DB_ENCRYPT_OVERRIDE" ]; then DB_ENCRYPT="$DB_ENCRYPT_OVERRIDE"; fi
if [ -n "$DB_TRUST_CERT_OVERRIDE" ]; then DB_TRUST_SERVER_CERTIFICATE="$DB_TRUST_CERT_OVERRIDE"; fi
if [ -z "$DB_TRUST_SERVER_CERTIFICATE" ]; then DB_TRUST_SERVER_CERTIFICATE="false"; fi
if [ -z "$DB_ENCRYPT" ]; then DB_ENCRYPT="true"; fi
SQLCMD_TLS_ARGS=()
if [ "$DB_ENCRYPT" != "false" ]; then SQLCMD_TLS_ARGS+=(-N); fi
if [ "$DB_TRUST_SERVER_CERTIFICATE" = "true" ]; then SQLCMD_TLS_ARGS+=(-C); fi

FILTER_TABLE=""
SEARCH_KEYWORD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--table)
      FILTER_TABLE="$2"
      shift 2
      ;;
    -q|--query)
      SEARCH_KEYWORD="$2"
      shift 2
      ;;
    -h|--help)
      echo -e "${BOLD}사용법:${NC} $0 [옵션]"
      echo ""
      echo "옵션:"
      echo "  -t, --table <테이블명>  특정 테이블만 조회 (users, user_sessions, canvas_info, redis_server, cpp_server)"
      echo "  -q, --query <키워드>    문자열/ID 컬럼 대상 검색"
      echo "  -h, --help              도움말 출력"
      echo ""
      exit 0
      ;;
    *)
      SEARCH_KEYWORD="$1"
      shift
      ;;
  esac
done

echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN}             MS SQL Server 데이터 조회 및 검색                  ${NC}"
echo -e "${CYAN}================================================================${NC}"
echo -e "  - 접속 대상: $MSSQL_USER@$MSSQL_HOST:$MSSQL_PORT/$MSSQL_DB"
if [ -n "$FILTER_TABLE" ]; then
  echo -e "  - 필터 테이블: $FILTER_TABLE"
fi
if [ -n "$SEARCH_KEYWORD" ]; then
  echo -e "  - 검색 키워드: \"$SEARCH_KEYWORD\""
fi
echo -e "${CYAN}================================================================${NC}\n"

run_query() {
  local sql="$1"
  if command -v sqlcmd &> /dev/null; then
    sqlcmd -S "$MSSQL_HOST,$MSSQL_PORT" -U "$MSSQL_USER" -P "$MSSQL_PASS" "${SQLCMD_TLS_ARGS[@]}" -b -I -d "$MSSQL_DB" -Q "$sql" -W 2>&1
  elif [[ "$MSSQL_HOST" == "127.0.0.1" || "$MSSQL_HOST" == "localhost" || "$MSSQL_HOST" == "::1" ]] \
      && docker inspect --format '{{.State.Running}}' agora-mssql 2>/dev/null | grep -q '^true$'; then
    docker exec agora-mssql /opt/mssql-tools18/bin/sqlcmd \
      -S localhost -U "$MSSQL_USER" -P "$MSSQL_PASS" "${SQLCMD_TLS_ARGS[@]}" -b -I -d "$MSSQL_DB" -Q "$sql" -W 2>&1
  else
    echo "[ERROR] sqlcmd is required for the configured SQL Server endpoint $MSSQL_HOST:$MSSQL_PORT. Docker fallback is only available for a running local agora-mssql container." >&2
    return 127
  fi
}

display_table_data() {
  local tbl="$1"
  local filter="$2"

  echo -e "${YELLOW}▶ 테이블: [$tbl]${NC}"
  local count_sql="SET NOCOUNT ON; SELECT COUNT(*) FROM [$tbl];"
  local raw_cnt
  if ! raw_cnt=$(run_query "$count_sql" 2>&1); then
    if echo "$raw_cnt" | grep -iq "Invalid object name"; then
      echo -e "  ${RED}(테이블 [$tbl] 이 데이터베이스에 존재하지 않습니다)${NC}\n"
      return 0
    fi
    echo -e "  ${RED}SQL 조회 실패:${NC}\n$raw_cnt" >&2
    return 1
  fi
  if echo "$raw_cnt" | grep -iq "Invalid object name"; then
    echo -e "  ${RED}(테이블 [$tbl] 이 데이터베이스에 존재하지 않습니다)${NC}\n"
    return
  fi

  local cnt
  cnt=$(echo "$raw_cnt" | grep -v '^\s*$' | tail -n 1 | tr -dc '0-9')
  cnt="${cnt:-0}"
  echo -e "  총 레코드 수: ${BOLD}$cnt${NC} 건"

  if [ "$cnt" -eq 0 ]; then
    echo -e "  ${YELLOW}(데이터가 비어 있습니다)${NC}\n"
    return
  fi

  local select_sql="SET NOCOUNT ON; "
  if [ -n "$filter" ]; then
    case "$tbl" in
      "$MSSQL_TABLE_USERS")
        select_sql+="SELECT user_id, email, nickname, tag_number, role, status, oauth_provider, FORMAT(created_at, 'yyyy-MM-dd HH:mm:ss') AS created_at FROM [$tbl] WHERE email LIKE '%$filter%' OR nickname LIKE '%$filter%' OR CAST(user_id AS VARCHAR) = '$filter' OR role LIKE '%$filter%' OR status LIKE '%$filter%';"
        ;;
      "user_sessions")
        select_sql+="SELECT user_id, cpp_server_id, canvas_id, is_accessed, FORMAT(last_login_at, 'yyyy-MM-dd HH:mm:ss') AS last_login, FORMAT(updated_at, 'yyyy-MM-dd HH:mm:ss') AS updated_at FROM [$tbl] WHERE CAST(user_id AS VARCHAR) = '$filter' OR CAST(canvas_id AS VARCHAR) = '$filter' OR CAST(cpp_server_id AS VARCHAR) = '$filter';"
        ;;
      "$MSSQL_TABLE_CANVAS_INFO")
        select_sql+="SELECT canvas_id, redis_id, cpp_server_id, is_cached, FORMAT(created_at, 'yyyy-MM-dd HH:mm:ss') AS created_at, FORMAT(updated_at, 'yyyy-MM-dd HH:mm:ss') AS updated_at FROM [$tbl] WHERE CAST(canvas_id AS VARCHAR) = '$filter' OR CAST(redis_id AS VARCHAR) = '$filter' OR CAST(cpp_server_id AS VARCHAR) = '$filter';"
        ;;
      "$MSSQL_TABLE_REDIS_SERVER")
        select_sql+="SELECT redis_id, redis_ip, redis_port, is_activated, FORMAT(created_at, 'yyyy-MM-dd HH:mm:ss') AS created_at FROM [$tbl] WHERE redis_ip LIKE '%$filter%' OR redis_port LIKE '%$filter%' OR CAST(redis_id AS VARCHAR) = '$filter';"
        ;;
      "$MSSQL_TABLE_CPP_SERVER")
        select_sql+="SELECT server_id, server_ip, server_port, ws_port, is_activated, FORMAT(created_at, 'yyyy-MM-dd HH:mm:ss') AS created_at FROM [$tbl] WHERE server_ip LIKE '%$filter%' OR server_port LIKE '%$filter%' OR ws_port LIKE '%$filter%' OR CAST(server_id AS VARCHAR) = '$filter';"
        ;;
      *)
        select_sql+="SELECT * FROM [$tbl];"
        ;;
    esac
  else
    case "$tbl" in
      "$MSSQL_TABLE_USERS")
        select_sql+="SELECT user_id, email, nickname, tag_number, role, status, oauth_provider, FORMAT(created_at, 'yyyy-MM-dd HH:mm:ss') AS created_at FROM [$tbl];"
        ;;
      "user_sessions")
        select_sql+="SELECT user_id, cpp_server_id, canvas_id, is_accessed, FORMAT(last_login_at, 'yyyy-MM-dd HH:mm:ss') AS last_login, FORMAT(updated_at, 'yyyy-MM-dd HH:mm:ss') AS updated_at FROM [$tbl];"
        ;;
      "$MSSQL_TABLE_CANVAS_INFO")
        select_sql+="SELECT canvas_id, redis_id, cpp_server_id, is_cached, FORMAT(created_at, 'yyyy-MM-dd HH:mm:ss') AS created_at, FORMAT(updated_at, 'yyyy-MM-dd HH:mm:ss') AS updated_at FROM [$tbl];"
        ;;
      "$MSSQL_TABLE_REDIS_SERVER")
        select_sql+="SELECT redis_id, redis_ip, redis_port, is_activated, FORMAT(created_at, 'yyyy-MM-dd HH:mm:ss') AS created_at FROM [$tbl];"
        ;;
      "$MSSQL_TABLE_CPP_SERVER")
        select_sql+="SELECT server_id, server_ip, server_port, ws_port, is_activated, FORMAT(created_at, 'yyyy-MM-dd HH:mm:ss') AS created_at FROM [$tbl];"
        ;;
      *)
        select_sql+="SELECT * FROM [$tbl];"
        ;;
    esac
  fi

  local result
  if ! result=$(run_query "$select_sql" 2>&1); then
    echo -e "  ${RED}SQL 조회 실패:${NC}\n$result" >&2
    return 1
  fi
  echo "$result" | sed 's/^/  /'
  echo ""
}

TABLES=("$MSSQL_TABLE_USERS" "user_sessions" "$MSSQL_TABLE_CANVAS_INFO" "$MSSQL_TABLE_REDIS_SERVER" "$MSSQL_TABLE_CPP_SERVER")

if [ -n "$FILTER_TABLE" ]; then
  display_table_data "$FILTER_TABLE" "$SEARCH_KEYWORD"
else
  for t in "${TABLES[@]}"; do
    display_table_data "$t" "$SEARCH_KEYWORD"
  done
fi

echo -e "${GREEN}[OK] MS SQL 데이터 조회가 완료되었습니다.${NC}\n"
