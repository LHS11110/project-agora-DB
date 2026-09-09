#!/bin/bash
# ==============================================================================
# Redis Stack (RedisJSON + RediSearch) Database & User Initialization Script
# .env 설정을 기반으로 일반 사용자 ACL 계정 생성, 인덱스 생성 (샘플 데이터 제외)
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# .env 파일이 있으면 로드
if [ -f "$SCRIPT_DIR/.env" ]; then
  export $(grep -v '^#' "$SCRIPT_DIR/.env" | xargs)
elif [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

REDIS_HOST="127.0.0.1"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_ADMIN_PASS="${REDIS_PASSWORD:-AgoraRedisSecret@Passw0rd!2026}"
REDIS_USER="${REDIS_USER:-agora_user}"
REDIS_USER_PASS="${REDIS_USER_PASSWORD:-AgoraUserSecret@Passw0rd!2026}"
REDIS_INDEX_NAME="${REDIS_INDEX_NAME:-idx:canvas}"
REDIS_KEY_PREFIX="${REDIS_KEY_PREFIX:-canvas:}"

# redis-cli 실행 래퍼 함수 (로컬 redis-cli 우선, 없으면 docker exec fallback)
if command -v redis-cli &> /dev/null; then
  run_admin_cli() {
    REDISCLI_AUTH="$REDIS_ADMIN_PASS" redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" "$@"
  }
  run_user_cli() {
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" --user "$REDIS_USER" -a "$REDIS_USER_PASS" --no-auth-warning "$@"
  }
else
  run_admin_cli() {
    docker exec -e REDISCLI_AUTH="$REDIS_ADMIN_PASS" agora-redis-stack redis-cli "$@"
  }
  run_user_cli() {
    docker exec agora-redis-stack redis-cli --user "$REDIS_USER" -a "$REDIS_USER_PASS" --no-auth-warning "$@"
  }
fi

echo "=== 1. Redis ACL 사용자 ($REDIS_USER) 생성 및 권한 부여 ==="
# 네임스페이스(~${REDIS_KEY_PREFIX}*) 및 인덱스(~${REDIS_INDEX_NAME}*)에 한해 CRUD 및 검색 전체 권한 부여
run_admin_cli ACL SETUSER "$REDIS_USER" reset on ">$REDIS_USER_PASS" "~${REDIS_KEY_PREFIX}*" "~${REDIS_INDEX_NAME}*" '&*' '+@all'
echo "[OK] 사용자($REDIS_USER) ACL 생성 완료 (허용 대상: ~${REDIS_KEY_PREFIX}*, ~${REDIS_INDEX_NAME}*)"

echo -e "\n=== 2. Redis Stack RediSearch 인덱스 ($REDIS_INDEX_NAME) 생성 ==="
# 인덱스가 이미 존재하는지 확인
if run_admin_cli FT._LIST | grep -q "^${REDIS_INDEX_NAME}$"; then
  echo "인덱스(${REDIS_INDEX_NAME})가 이미 존재합니다. 생성을 건너뜁니다."
else
  run_admin_cli FT.CREATE "$REDIS_INDEX_NAME" ON JSON PREFIX 1 "$REDIS_KEY_PREFIX" SCHEMA \
      '$["canvas-name"]' AS canvas_name TEXT SORTABLE \
      '$["canvas-id"]' AS canvas_id NUMERIC SORTABLE \
      '$.admin' AS admin NUMERIC \
      '$.peoples[*]' AS peoples NUMERIC \
      '$["init-group"]' AS init_group TAG
  echo "[OK] RediSearch 인덱스($REDIS_INDEX_NAME) 생성 완료 (초기 데이터 미삽입)"
fi

echo -e "\n=== 3. 신규 사용자($REDIS_USER) 인증 및 인덱스($REDIS_INDEX_NAME) 정보 조회 검증 ==="
run_user_cli ping
run_user_cli FT.INFO "$REDIS_INDEX_NAME" | head -n 4

echo -e "\n[SUCCESS] Redis Stack 사용자($REDIS_USER) 및 인덱스($REDIS_INDEX_NAME) 초기화가 완료되었습니다."
