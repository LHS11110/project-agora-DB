#!/bin/bash
# ==============================================================================
# Redis Stack (RedisJSON + RediSearch) Database & User Initialization Script
# .env 설정을 기반으로 일반 사용자 ACL 계정 생성, 인덱스 생성 및 샘플 데이터 등록
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
run_admin_cli ACL SETUSER "$REDIS_USER" on ">$REDIS_USER_PASS" '~*' '&*' '+@all'
echo "[OK] 사용자($REDIS_USER) ACL 생성 완료"

echo -e "\n=== 2. Redis Stack RediSearch 인덱스 (idx:canvas) 생성 ==="
# 인덱스가 이미 존재하는지 확인
if run_admin_cli FT._LIST | grep -q "^idx:canvas$"; then
  echo "인덱스(idx:canvas)가 이미 존재합니다. 생성을 건너뜁니다."
else
  run_admin_cli FT.CREATE idx:canvas ON JSON PREFIX 1 "canvas:" SCHEMA \
      '$["canvas-name"]' AS canvas_name TEXT SORTABLE \
      '$["canvas-id"]' AS canvas_id NUMERIC SORTABLE \
      '$.admin' AS admin NUMERIC \
      '$.peoples[*]' AS peoples NUMERIC \
      '$["init-group"]' AS init_group TAG
  echo "[OK] RediSearch 인덱스(idx:canvas) 생성 완료"
fi

echo -e "\n=== 3. RedisJSON 샘플 캔버스 데이터 저장 (Key: canvas:1) ==="
run_admin_cli JSON.SET canvas:1 $ '{
  "canvas-name": "Agora Architecture Canvas",
  "canvas-id": 1,
  "admin": 1000,
  "peoples": [1000, 1001, 1002, 1003],
  "inner-group": {
    "group-name1": [1001, 1002],
    "group-name2": [1003],
    "init-group-name": [1001, 1002, 1003],
    "admin-group": [1000]
  },
  "items": {
    "item-name1": {
      "type": 1,
      "pos": [120.5, 340.8],
      "data1": "sample data",
      "permission": {
        "admin-group": 7,
        "group-name1": 5,
        "group-name2": 1
      }
    }
  },
  "init-group": "init-group-name"
}'
echo "[OK] 샘플 데이터 저장 완료"

echo -e "\n=== 4. 신규 사용자($REDIS_USER)로 데이터 조회 검증 (JSON.GET) ==="
run_user_cli JSON.GET canvas:1

echo -e "\n\n=== 5. 신규 사용자($REDIS_USER)로 RediSearch 검색 쿼리 검증 (FT.SEARCH) ==="
run_user_cli FT.SEARCH idx:canvas "@admin:[1000 1000]"

echo -e "\n\n[SUCCESS] Redis Stack 사용자($REDIS_USER) 및 데이터 초기화가 완료되었습니다."
