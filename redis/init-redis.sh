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

REDIS_BIND_IP="${REDIS_BIND_IP:-127.0.0.1}"
REDIS_EXTERNAL_IP="${REDIS_EXTERNAL_IP:-127.0.0.1}"
REDIS_EXTERNAL_PORT="${REDIS_EXTERNAL_PORT:-${REDIS_PORT:-6379}}"

# 로컬 스크립트 실행 시 접속 호스트 결정 (0.0.0.0 바인딩인 경우 로컬 루프백 127.0.0.1 접속)
if [ "$REDIS_BIND_IP" = "0.0.0.0" ]; then
  REDIS_HOST="127.0.0.1"
else
  REDIS_HOST="$REDIS_BIND_IP"
fi
REDIS_PORT="$REDIS_EXTERNAL_PORT"
REDIS_HOST="${REDIS_CONNECT_HOST:-$REDIS_HOST}"
REDIS_PORT="${REDIS_CONNECT_PORT:-$REDIS_PORT}"
: "${REDIS_PASSWORD:?REDIS_PASSWORD must be set in redis/.env}"
REDIS_ADMIN_PASS="$REDIS_PASSWORD"
REDIS_USER="${REDIS_USER:-agora_user}"
: "${REDIS_USER_PASSWORD:?REDIS_USER_PASSWORD must be set in redis/.env}"
REDIS_USER_PASS="$REDIS_USER_PASSWORD"
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
    if [ "$(docker inspect -f '{{.State.Running}}' agora-redis-primary 2>/dev/null || true)" = "true" ]; then
      docker exec -e REDISCLI_AUTH="$REDIS_ADMIN_PASS" agora-redis-primary redis-cli "$@"
    elif [ "$(docker inspect -f '{{.State.Running}}' agora-redis-node 2>/dev/null || true)" = "true" ]; then
      docker exec -e REDISCLI_AUTH="$REDIS_ADMIN_PASS" agora-redis-node \
        redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" "$@"
    else
    docker exec -e REDISCLI_AUTH="$REDIS_ADMIN_PASS" agora-redis-stack redis-cli "$@"
    fi
  }
  run_user_cli() {
    if [ "$(docker inspect -f '{{.State.Running}}' agora-redis-primary 2>/dev/null || true)" = "true" ]; then
      docker exec agora-redis-primary redis-cli --user "$REDIS_USER" -a "$REDIS_USER_PASS" --no-auth-warning "$@"
    elif [ "$(docker inspect -f '{{.State.Running}}' agora-redis-node 2>/dev/null || true)" = "true" ]; then
      docker exec agora-redis-node redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" \
        --user "$REDIS_USER" -a "$REDIS_USER_PASS" --no-auth-warning "$@"
    else
      docker exec agora-redis-stack redis-cli --user "$REDIS_USER" -a "$REDIS_USER_PASS" --no-auth-warning "$@"
    fi
  }
fi

echo "=== 1. Redis ACL 사용자 ($REDIS_USER) 생성 및 권한 부여 ==="
# Keep commands used by the BE and failover/inspection checks, limited to the
# application's key namespace and RediSearch index.
run_admin_cli ACL SETUSER "$REDIS_USER" reset on ">$REDIS_USER_PASS" \
  "~${REDIS_KEY_PREFIX}*" "~${REDIS_INDEX_NAME}*" resetchannels -@all \
  +auth +ping +role +json.get +json.set +json.arrlen +json.arrappend +json.del \
  +get +del +exists +keys +eval +ft.search +ft.info
echo "[OK] 사용자($REDIS_USER) ACL 생성 완료 (제한된 명령 및 키 네임스페이스 적용)"

echo -e "\n=== 2. Redis Stack RediSearch 인덱스 ($REDIS_INDEX_NAME) 생성 ==="
# 인덱스가 이미 존재하는지 확인
if run_admin_cli FT._LIST | grep -q "^${REDIS_INDEX_NAME}$"; then
  echo "인덱스(${REDIS_INDEX_NAME})가 이미 존재합니다. 최신 스키마 템플릿 적용을 위해 인덱스를 재동기화합니다..."
  NUM_DOCS=$(run_admin_cli FT.INFO "$REDIS_INDEX_NAME" | grep -A 1 "num_docs" | tail -n 1 | tr -dc '0-9' || echo "0")
  if [ "$NUM_DOCS" = "0" ] || [ -z "$NUM_DOCS" ]; then
    run_admin_cli FT.DROPINDEX "$REDIS_INDEX_NAME"
    run_admin_cli FT.CREATE "$REDIS_INDEX_NAME" ON JSON PREFIX 1 "$REDIS_KEY_PREFIX" SCHEMA \
        '$["canvas-name"]' AS canvas_name TEXT SORTABLE \
        '$["canvas-id"]' AS canvas_id NUMERIC SORTABLE \
        '$["admin-user-id"]' AS admin_user_id NUMERIC \
        '$.description' AS description TEXT \
        '$["canvas-password-hash"]' AS canvas_password_hash TAG \
        '$.people[*]' AS people NUMERIC \
        '$["init-group"]' AS init_group TAG
    echo "[OK] RediSearch 인덱스($REDIS_INDEX_NAME) 최신 스키마로 재생성 완료"
  else
    if ! run_admin_cli FT.INFO "$REDIS_INDEX_NAME" | grep -q "canvas_password_hash"; then
      run_admin_cli FT.ALTER "$REDIS_INDEX_NAME" SCHEMA ADD '$["admin-user-id"]' AS admin_user_id NUMERIC
      run_admin_cli FT.ALTER "$REDIS_INDEX_NAME" SCHEMA ADD '$.description' AS description TEXT
      run_admin_cli FT.ALTER "$REDIS_INDEX_NAME" SCHEMA ADD '$["canvas-password-hash"]' AS canvas_password_hash TAG
      run_admin_cli FT.ALTER "$REDIS_INDEX_NAME" SCHEMA ADD '$.people[*]' AS people NUMERIC
      echo "[OK] RediSearch 인덱스($REDIS_INDEX_NAME) 속성 추가 완료"
    fi
  fi
else
  run_admin_cli FT.CREATE "$REDIS_INDEX_NAME" ON JSON PREFIX 1 "$REDIS_KEY_PREFIX" SCHEMA \
      '$["canvas-name"]' AS canvas_name TEXT SORTABLE \
      '$["canvas-id"]' AS canvas_id NUMERIC SORTABLE \
      '$["admin-user-id"]' AS admin_user_id NUMERIC \
      '$.description' AS description TEXT \
      '$["canvas-password-hash"]' AS canvas_password_hash TAG \
      '$.people[*]' AS people NUMERIC \
      '$["init-group"]' AS init_group TAG
  echo "[OK] RediSearch 인덱스($REDIS_INDEX_NAME) 생성 완료 (초기 데이터 미삽입)"
fi

echo -e "\n=== 3. 신규 사용자($REDIS_USER) 인증 및 인덱스($REDIS_INDEX_NAME) 정보 조회 검증 ==="
run_user_cli ping
run_user_cli FT.INFO "$REDIS_INDEX_NAME" | head -n 4

echo -e "\n=== 4. MS SQL에 Redis 외부 접속 정보($REDIS_EXTERNAL_IP:$REDIS_EXTERNAL_PORT) 등록 ==="
if [ -f "$SCRIPT_DIR/register-to-mssql.sh" ]; then
  bash "$SCRIPT_DIR/register-to-mssql.sh"
else
  echo "[WARN] $SCRIPT_DIR/register-to-mssql.sh 스크립트를 찾을 수 없어 MS SQL 등록을 건너뜁니다."
fi

echo -e "\n[SUCCESS] Redis Stack 사용자/인덱스 구축 및 MS SQL 서버 등록이 완료되었습니다."
