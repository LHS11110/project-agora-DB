#!/bin/bash
# ==============================================================================
# Agora Storage Connection & CRUD Integration Test Suite
# 각 저장소(MS SQL, Elasticsearch, Redis Stack)의 .env 동적 설정을 기반으로
# 일반 사용자 계정 인증 및 독립적인 CRUD/Search/Scope 권한을 검증하는 테스트 스크립트
# ==============================================================================

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

log_test_pass() {
  echo -e "  [${GREEN}PASS${NC}] $1"
  PASSED_TESTS=$((PASSED_TESTS + 1))
  TOTAL_TESTS=$((TOTAL_TESTS + 1))
}

log_test_fail() {
  echo -e "  [${RED}FAIL${NC}] $1"
  if [ -n "$2" ]; then
    echo -e "         ${RED}원인: $2${NC}"
  fi
  FAILED_TESTS=$((FAILED_TESTS + 1))
  TOTAL_TESTS=$((TOTAL_TESTS + 1))
}

echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN}      Agora Storage User Connection & CRUD Test Suite           ${NC}"
echo -e "${CYAN}================================================================${NC}\n"

# ==============================================================================
# 1. MS SQL 테스트 (mssql/.env 로드)
# ==============================================================================
echo -e "${YELLOW}[1/3] MS SQL Server 사용자 CRUD 테스트${NC}"

if [ -f "$ROOT_DIR/mssql/.env" ]; then
  MSSQL_HOST="127.0.0.1"
  MSSQL_PORT=$(grep -v '^#' "$ROOT_DIR/mssql/.env" | grep 'MSSQL_PORT=' | cut -d '=' -f2- | tr -d '\r' || echo "1433")
  MSSQL_DB=$(grep -v '^#' "$ROOT_DIR/mssql/.env" | grep 'MSSQL_DB=' | cut -d '=' -f2- | tr -d '\r' || echo "agora_db")
  MSSQL_USER=$(grep -v '^#' "$ROOT_DIR/mssql/.env" | grep 'MSSQL_USER=' | cut -d '=' -f2- | tr -d '\r' || echo "agora_user")
  MSSQL_PASS=$(grep -v '^#' "$ROOT_DIR/mssql/.env" | grep 'MSSQL_PASSWORD=' | cut -d '=' -f2- | tr -d '\r' || echo "AgoraUserSecret@Passw0rd!2026")
  MSSQL_TABLE_REDIS_SERVER=$(grep -v '^#' "$ROOT_DIR/mssql/.env" | grep 'MSSQL_TABLE_REDIS_SERVER=' | cut -d '=' -f2- | tr -d '\r' || echo "redis_server")
  MSSQL_TABLE_CANVAS_CACHE=$(grep -v '^#' "$ROOT_DIR/mssql/.env" | grep 'MSSQL_TABLE_CANVAS_CACHE=' | cut -d '=' -f2- | tr -d '\r' || echo "canvas_cache")
else
  MSSQL_HOST="127.0.0.1"
  MSSQL_PORT="1433"
  MSSQL_DB="agora_db"
  MSSQL_USER="agora_user"
  MSSQL_PASS="AgoraUserSecret@Passw0rd!2026"
  MSSQL_TABLE_REDIS_SERVER="redis_server"
  MSSQL_TABLE_CANVAS_CACHE="canvas_cache"
fi

echo "  - 접속 정보: $MSSQL_USER@$MSSQL_HOST:$MSSQL_PORT/$MSSQL_DB"
echo "  - 검증 테이블: $MSSQL_TABLE_REDIS_SERVER, $MSSQL_TABLE_CANVAS_CACHE"

run_mssql_query() {
  local query="$1"
  if command -v sqlcmd &> /dev/null; then
    sqlcmd -S "$MSSQL_HOST,$MSSQL_PORT" -U "$MSSQL_USER" -P "$MSSQL_PASS" -C -d "$MSSQL_DB" -Q "$query" -W -h -1 2>&1
  else
    docker exec agora-mssql /opt/mssql-tools18/bin/sqlcmd \
      -S localhost -U "$MSSQL_USER" -P "$MSSQL_PASS" -C -d "$MSSQL_DB" -Q "$query" -W -h -1 2>&1
  fi
}

# (1-1) 사용자 인증 및 DB 소유권(dbo) 확인
AUTH_OUT=$(run_mssql_query "SET NOCOUNT ON; SELECT DB_NAME() + ':' + USER_NAME() + ':' + SUSER_SNAME();" | tr -d '[:space:]')
if echo "$AUTH_OUT" | grep -q "$MSSQL_DB:dbo:$MSSQL_USER"; then
  log_test_pass "사용자 인증 및 데이터베이스 소유자(dbo) 권한 확인 ($MSSQL_USER -> dbo)"
else
  log_test_fail "사용자 인증 또는 DB 소유권 확인 실패" "$AUTH_OUT"
fi

# (1-2) 설정된 테이블 존재 여부 확인
TBL_CHECK_OUT=$(run_mssql_query "SET NOCOUNT ON; SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME IN ('$MSSQL_TABLE_REDIS_SERVER', '$MSSQL_TABLE_CANVAS_CACHE');" | tr -dc '0-9')
if [ "$TBL_CHECK_OUT" = "2" ]; then
  log_test_pass "환경변수 지정 테이블($MSSQL_TABLE_REDIS_SERVER, $MSSQL_TABLE_CANVAS_CACHE) 생성 확인"
else
  log_test_fail "테이블 생성 확인 실패 (발견된 테이블 수: $TBL_CHECK_OUT / 2)" "$TBL_CHECK_OUT"
fi

# (1-3) 데이터 삽입 [Create]
MSSQL_INS_OUT=$(run_mssql_query "SET NOCOUNT ON; INSERT INTO [$MSSQL_TABLE_REDIS_SERVER] (redis_ip, redis_port) VALUES ('127.0.0.1', '6379'); INSERT INTO [$MSSQL_TABLE_CANVAS_CACHE] (canvas_name, redis_ip, redis_port, is_cached) VALUES (N'test-crud-canvas', '127.0.0.1', '6379', 0); SELECT COUNT(*) FROM [$MSSQL_TABLE_CANVAS_CACHE] WHERE canvas_name = N'test-crud-canvas';" | tr -dc '0-9')
if [ "$MSSQL_INS_OUT" = "1" ]; then
  log_test_pass "테이블($MSSQL_TABLE_REDIS_SERVER, $MSSQL_TABLE_CANVAS_CACHE) 데이터 삽입 [Create] 성공"
else
  log_test_fail "테이블 데이터 삽입 실패" "$MSSQL_INS_OUT"
fi

# (1-4) 데이터 조회 [Read]
MSSQL_READ_OUT=$(run_mssql_query "SET NOCOUNT ON; SELECT is_cached FROM [$MSSQL_TABLE_CANVAS_CACHE] WHERE canvas_name = N'test-crud-canvas';" | tr -dc '0-9')
if [ "$MSSQL_READ_OUT" = "0" ]; then
  log_test_pass "테이블($MSSQL_TABLE_CANVAS_CACHE) 데이터 조회 [Read] 성공 (is_cached: 0)"
else
  log_test_fail "테이블($MSSQL_TABLE_CANVAS_CACHE) 데이터 조회 실패" "$MSSQL_READ_OUT"
fi

# (1-5) 데이터 수정 [Update]
MSSQL_UPD_OUT=$(run_mssql_query "SET NOCOUNT ON; UPDATE [$MSSQL_TABLE_CANVAS_CACHE] SET is_cached = 1 WHERE canvas_name = N'test-crud-canvas'; SELECT is_cached FROM [$MSSQL_TABLE_CANVAS_CACHE] WHERE canvas_name = N'test-crud-canvas';" | tr -dc '0-9')
if [ "$MSSQL_UPD_OUT" = "1" ]; then
  log_test_pass "테이블($MSSQL_TABLE_CANVAS_CACHE) 데이터 수정 [Update] 성공 (is_cached: 0 -> 1)"
else
  log_test_fail "테이블($MSSQL_TABLE_CANVAS_CACHE) 데이터 수정 실패" "$MSSQL_UPD_OUT"
fi

# (1-6) 데이터 삭제 [Delete]
MSSQL_DEL_OUT=$(run_mssql_query "SET NOCOUNT ON; DELETE FROM [$MSSQL_TABLE_CANVAS_CACHE] WHERE canvas_name = N'test-crud-canvas'; DELETE FROM [$MSSQL_TABLE_REDIS_SERVER] WHERE redis_ip = '127.0.0.1' AND redis_port = '6379'; SELECT COUNT(*) FROM [$MSSQL_TABLE_CANVAS_CACHE] WHERE canvas_name = N'test-crud-canvas';" | tr -dc '0-9')
if [ "$MSSQL_DEL_OUT" = "0" ]; then
  log_test_pass "테이블($MSSQL_TABLE_CANVAS_CACHE, $MSSQL_TABLE_REDIS_SERVER) 데이터 삭제 [Delete] 성공 (클린업 완료)"
else
  log_test_fail "테이블 데이터 삭제 실패" "$MSSQL_DEL_OUT"
fi

echo ""

# ==============================================================================
# 2. Elasticsearch 테스트 (elasticsearch/.env 로드)
# ==============================================================================
echo -e "${YELLOW}[2/3] Elasticsearch 사용자 CRUD/Search 테스트${NC}"

if [ -f "$ROOT_DIR/elasticsearch/.env" ]; then
  ES_PORT=$(grep -v '^#' "$ROOT_DIR/elasticsearch/.env" | grep 'ES_PORT=' | cut -d '=' -f2- | tr -d '\r' || echo "9200")
  ES_INDEX=$(grep -v '^#' "$ROOT_DIR/elasticsearch/.env" | grep 'ES_INDEX=' | cut -d '=' -f2- | tr -d '\r' || echo "canvas")
  ES_USER=$(grep -v '^#' "$ROOT_DIR/elasticsearch/.env" | grep 'ES_USER_NAME=' | cut -d '=' -f2- | tr -d '\r' || echo "agora_user")
  ES_PASS=$(grep -v '^#' "$ROOT_DIR/elasticsearch/.env" | grep 'ES_USER_PASSWORD=' | cut -d '=' -f2- | tr -d '\r' || echo "AgoraUserSecret@Passw0rd!2026")
else
  ES_PORT="9200"
  ES_INDEX="canvas"
  ES_USER="agora_user"
  ES_PASS="AgoraUserSecret@Passw0rd!2026"
fi

ES_URL="http://127.0.0.1:$ES_PORT"
echo "  - 접속 정보: $ES_USER@$ES_URL (인덱스: $ES_INDEX)"

# (2-1) 사용자 인증 및 역할(Role) 확인
ES_AUTH_STATUS=$(curl -s -o /tmp/es_auth_resp.json -w "%{http_code}" -u "$ES_USER:$ES_PASS" "$ES_URL/_security/_authenticate")
if [ "$ES_AUTH_STATUS" = "200" ] && grep -q "\"username\":\"$ES_USER\"" /tmp/es_auth_resp.json; then
  ROLES=$(grep -o '"roles":\[[^]]*\]' /tmp/es_auth_resp.json || echo "")
  log_test_pass "사용자 인증 성공 ($ES_USER, $ROLES)"
else
  log_test_fail "사용자 인증 실패 (HTTP $ES_AUTH_STATUS)" "$(cat /tmp/es_auth_resp.json 2>/dev/null)"
fi
rm -f /tmp/es_auth_resp.json

# (2-2) 인덱스 존재 및 접근 확인
ES_IDX_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -u "$ES_USER:$ES_PASS" "$ES_URL/$ES_INDEX")
if [ "$ES_IDX_STATUS" = "200" ]; then
  log_test_pass "인덱스($ES_INDEX) 존재 및 접근 권한 확인"
else
  log_test_fail "인덱스($ES_INDEX) 접근 실패 (HTTP $ES_IDX_STATUS)"
fi

# (2-3) 도큐먼트 삽입 [Create]
ES_DOC_ID="test-crud-doc"
ES_INS_RESP=$(curl -s -u "$ES_USER:$ES_PASS" -X PUT "$ES_URL/$ES_INDEX/_doc/$ES_DOC_ID?refresh=true" \
  -H 'Content-Type: application/json' \
  -d '{"canvas-name": "Agora Test Canvas", "canvas-id": 8888, "admin": 999}')
if echo "$ES_INS_RESP" | grep -qE '"result":"(created|updated)"'; then
  log_test_pass "인덱스($ES_INDEX) 도큐먼트 삽입 [Create] 성공"
else
  log_test_fail "인덱스($ES_INDEX) 도큐먼트 삽입 실패" "$ES_INS_RESP"
fi

# (2-4) 도큐먼트 단건 조회 [Read]
ES_GET_RESP=$(curl -s -u "$ES_USER:$ES_PASS" -X GET "$ES_URL/$ES_INDEX/_doc/$ES_DOC_ID")
if echo "$ES_GET_RESP" | grep -q '"found":true'; then
  log_test_pass "인덱스($ES_INDEX) 도큐먼트 단건 조회 [Read] 성공"
else
  log_test_fail "인덱스($ES_INDEX) 도큐먼트 조회 실패" "$ES_GET_RESP"
fi

# (2-5) 검색 쿼리 수행 [Search]
ES_SEARCH_STATUS=$(curl -s -o /tmp/es_search_resp.json -w "%{http_code}" -u "$ES_USER:$ES_PASS" -X POST "$ES_URL/$ES_INDEX/_search" \
  -H 'Content-Type: application/json' \
  -d '{"query": {"match": {"canvas-name": "Agora"}}}')
if [ "$ES_SEARCH_STATUS" = "200" ] && grep -q '"hits":' /tmp/es_search_resp.json; then
  log_test_pass "인덱스($ES_INDEX) 검색 쿼리 [Search] (match: Agora) 성공"
else
  log_test_fail "인덱스($ES_INDEX) 검색 쿼리 실패 (HTTP $ES_SEARCH_STATUS)" "$(cat /tmp/es_search_resp.json 2>/dev/null)"
fi
rm -f /tmp/es_search_resp.json

# (2-6) 도큐먼트 수정 [Update]
ES_UPD_RESP=$(curl -s -u "$ES_USER:$ES_PASS" -X POST "$ES_URL/$ES_INDEX/_update/$ES_DOC_ID" \
  -H 'Content-Type: application/json' \
  -d '{"doc": {"canvas-name": "Agora Test Canvas Updated"}}')
if echo "$ES_UPD_RESP" | grep -q '"result":"updated"'; then
  log_test_pass "인덱스($ES_INDEX) 도큐먼트 수정 [Update] 성공"
else
  log_test_fail "인덱스($ES_INDEX) 도큐먼트 수정 실패" "$ES_UPD_RESP"
fi

# (2-7) 도큐먼트 삭제 [Delete]
ES_DEL_RESP=$(curl -s -u "$ES_USER:$ES_PASS" -X DELETE "$ES_URL/$ES_INDEX/_doc/$ES_DOC_ID")
if echo "$ES_DEL_RESP" | grep -q '"result":"deleted"'; then
  log_test_pass "인덱스($ES_INDEX) 도큐먼트 삭제 [Delete] 성공 (클린업 완료)"
else
  log_test_fail "인덱스($ES_INDEX) 도큐먼트 삭제 실패" "$ES_DEL_RESP"
fi

echo ""

# ==============================================================================
# 3. Redis Stack 테스트 (redis/.env 로드)
# ==============================================================================
echo -e "${YELLOW}[3/3] Redis Stack 사용자 CRUD/Search/Scope 테스트${NC}"

if [ -f "$ROOT_DIR/redis/.env" ]; then
  REDIS_HOST="127.0.0.1"
  REDIS_PORT=$(grep -v '^#' "$ROOT_DIR/redis/.env" | grep 'REDIS_PORT=' | cut -d '=' -f2- | tr -d '\r' || echo "6379")
  REDIS_USER=$(grep -v '^#' "$ROOT_DIR/redis/.env" | grep 'REDIS_USER=' | cut -d '=' -f2- | tr -d '\r' || echo "agora_user")
  REDIS_PASS=$(grep -v '^#' "$ROOT_DIR/redis/.env" | grep 'REDIS_USER_PASSWORD=' | cut -d '=' -f2- | tr -d '\r' || echo "AgoraUserSecret@Passw0rd!2026")
  REDIS_INDEX_NAME=$(grep -v '^#' "$ROOT_DIR/redis/.env" | grep 'REDIS_INDEX_NAME=' | cut -d '=' -f2- | tr -d '\r' || echo "idx:canvas")
  REDIS_KEY_PREFIX=$(grep -v '^#' "$ROOT_DIR/redis/.env" | grep 'REDIS_KEY_PREFIX=' | cut -d '=' -f2- | tr -d '\r' || echo "canvas:")
else
  REDIS_HOST="127.0.0.1"
  REDIS_PORT="6379"
  REDIS_USER="agora_user"
  REDIS_PASS="AgoraUserSecret@Passw0rd!2026"
  REDIS_INDEX_NAME="idx:canvas"
  REDIS_KEY_PREFIX="canvas:"
fi

echo "  - 접속 정보: $REDIS_USER@$REDIS_HOST:$REDIS_PORT"
echo "  - 인덱스: $REDIS_INDEX_NAME, 네임스페이스(Prefix): $REDIS_KEY_PREFIX"

run_redis_user_cmd() {
  if command -v redis-cli &> /dev/null; then
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" --user "$REDIS_USER" -a "$REDIS_PASS" --no-auth-warning "$@" 2>&1
  else
    docker exec agora-redis-stack redis-cli --user "$REDIS_USER" -a "$REDIS_PASS" --no-auth-warning "$@" 2>&1
  fi
}

# (3-1) 사용자 인증 확인 (PING)
REDIS_PING_OUT=$(run_redis_user_cmd ping)
if echo "$REDIS_PING_OUT" | grep -q "PONG"; then
  log_test_pass "사용자 ACL 인증 성공 (PING -> PONG)"
else
  log_test_fail "사용자 ACL 인증 실패" "$REDIS_PING_OUT"
fi

# (3-2) RediSearch 인덱스 정보 조회
REDIS_INFO_OUT=$(run_redis_user_cmd FT.INFO "$REDIS_INDEX_NAME")
if echo "$REDIS_INFO_OUT" | grep -q "$REDIS_INDEX_NAME"; then
  log_test_pass "RediSearch 인덱스($REDIS_INDEX_NAME) 정보 조회 성공"
else
  log_test_fail "RediSearch 인덱스($REDIS_INDEX_NAME) 정보 조회 실패" "$REDIS_INFO_OUT"
fi

TEST_REDIS_KEY="${REDIS_KEY_PREFIX}test-crud"

# (3-3) 데이터 삽입 [Create]
REDIS_INSERT_OUT=$(run_redis_user_cmd JSON.SET "$TEST_REDIS_KEY" $ '{"canvas-name":"Test CRUD Canvas","canvas-id":100,"admin":1000}')
if echo "$REDIS_INSERT_OUT" | grep -q "OK"; then
  log_test_pass "RedisJSON 데이터 삽입 [Create] ($TEST_REDIS_KEY) 성공"
else
  log_test_fail "RedisJSON 데이터 삽입 실패" "$REDIS_INSERT_OUT"
fi

# (3-4) 데이터 조회 [Read]
REDIS_JSON_OUT=$(run_redis_user_cmd JSON.GET "$TEST_REDIS_KEY")
if echo "$REDIS_JSON_OUT" | grep -q "Test CRUD Canvas"; then
  log_test_pass "RedisJSON 데이터 조회 [Read] ($TEST_REDIS_KEY) 성공"
else
  log_test_fail "RedisJSON 데이터 조회 실패" "$REDIS_JSON_OUT"
fi

# (3-5) RediSearch 검색 쿼리 수행 [Search]
REDIS_SEARCH_OUT=$(run_redis_user_cmd FT.SEARCH "$REDIS_INDEX_NAME" "@admin:[1000 1000]")
if echo "$REDIS_SEARCH_OUT" | grep -q "$TEST_REDIS_KEY"; then
  log_test_pass "RediSearch 검색 쿼리 [Search] (FT.SEARCH $REDIS_INDEX_NAME) 성공"
else
  log_test_fail "RediSearch 검색 쿼리 실패" "$REDIS_SEARCH_OUT"
fi

# (3-6) 데이터 수정 [Update]
REDIS_UPDATE_OUT=$(run_redis_user_cmd JSON.SET "$TEST_REDIS_KEY" $.admin 2000)
if echo "$REDIS_UPDATE_OUT" | grep -q "OK"; then
  log_test_pass "RedisJSON 데이터 수정 [Update] ($TEST_REDIS_KEY $.admin 2000) 성공"
else
  log_test_fail "RedisJSON 데이터 수정 실패" "$REDIS_UPDATE_OUT"
fi

# (3-7) 데이터 삭제 [Delete]
REDIS_DEL_OUT=$(run_redis_user_cmd DEL "$TEST_REDIS_KEY")
if echo "$REDIS_DEL_OUT" | grep -q "1"; then
  log_test_pass "RedisJSON 데이터 삭제 [Delete] ($TEST_REDIS_KEY) 성공 (클린업 완료)"
else
  log_test_fail "RedisJSON 데이터 삭제 실패" "$REDIS_DEL_OUT"
fi

# (3-8) 타 네임스페이스 키 접근 차단 검증 [Scope Restriction]
REDIS_FORBIDDEN_OUT=$(run_redis_user_cmd SET other:unauthorized "forbidden_val")
if echo "$REDIS_FORBIDDEN_OUT" | grep -q "NOPERM"; then
  log_test_pass "타 키 접근 차단 [Scope Restriction] (SET other:unauthorized -> NOPERM 거절 확인)"
else
  log_test_fail "타 키 접근 차단 실패 (권한이 과도하게 열려있음)" "$REDIS_FORBIDDEN_OUT"
fi

echo ""

# ==============================================================================
# 최종 결과 요약
# ==============================================================================
echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN}                        테스트 결과 요약                        ${NC}"
echo -e "${CYAN}================================================================${NC}"
echo -e "  전체 테스트 수: $TOTAL_TESTS"
echo -e "  성공(PASSED):   ${GREEN}$PASSED_TESTS${NC}"
echo -e "  실패(FAILED):   ${RED}$FAILED_TESTS${NC}"
echo -e "${CYAN}================================================================${NC}"

if [ "$FAILED_TESTS" -eq 0 ]; then
  echo -e "\n${GREEN}[SUCCESS] 모든 저장소의 사용자 인증 및 CRUD 테스트를 통과했습니다! (저장소 데이터 무결성 유지)${NC}\n"
  exit 0
else
  echo -e "\n${RED}[FAILURE] 일부 테스트 항목이 실패했습니다.${NC}\n"
  exit 1
fi
