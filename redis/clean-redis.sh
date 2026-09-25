#!/bin/bash
# ==============================================================================
# Agora Redis Stack Data Cleanup Script
# Redis Stack (RedisJSON) 전용 데이터 초기화 스크립트
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes|--force)
      FORCE_CONFIRM=true
      shift
      ;;
    -h|--help)
      echo -e "${BOLD}사용법:${NC} $0 [옵션]"
      echo "  -y, --yes, --force   확인 프롬프트를 건너뛰고 즉시 삭제를 진행합니다"
      exit 0
      ;;
    *)
      shift
      ;;
  esac
done

if [ -f "$SCRIPT_DIR/.env" ]; then
  ENV_FILE="$SCRIPT_DIR/.env"
elif [ -f "$ROOT_DIR/redis/.env" ]; then
  ENV_FILE="$ROOT_DIR/redis/.env"
else
  ENV_FILE=""
fi

if [ -n "$ENV_FILE" ]; then
  REDIS_RAW_HOST=$(grep -v '^#' "$ENV_FILE" | grep 'REDIS_BIND_IP=' | cut -d '=' -f2- | tr -d '\r' || true)
  if [ -z "$REDIS_RAW_HOST" ]; then
    REDIS_RAW_HOST=$(grep -v '^#' "$ENV_FILE" | grep 'REDIS_EXTERNAL_IP=' | cut -d '=' -f2- | tr -d '\r' || echo "127.0.0.1")
  fi
  REDIS_HOST="127.0.0.1"
  if [ "$REDIS_RAW_HOST" != "0.0.0.0" ] && [ -n "$REDIS_RAW_HOST" ]; then
    REDIS_HOST="$REDIS_RAW_HOST"
  fi
  REDIS_PORT=$(grep -v '^#' "$ENV_FILE" | grep 'REDIS_EXTERNAL_PORT=' | cut -d '=' -f2- | tr -d '\r' || echo "6379")
  REDIS_ADMIN_PASS=$(grep -v '^#' "$ENV_FILE" | grep 'REDIS_PASSWORD=' | cut -d '=' -f2- | tr -d '\r' || echo "")
  REDIS_INDEX_NAME=$(grep -v '^#' "$ENV_FILE" | grep 'REDIS_INDEX_NAME=' | cut -d '=' -f2- | tr -d '\r' || echo "idx:canvas")
  REDIS_KEY_PREFIX=$(grep -v '^#' "$ENV_FILE" | grep 'REDIS_KEY_PREFIX=' | cut -d '=' -f2- | tr -d '\r' || echo "canvas:")
else
  REDIS_HOST="127.0.0.1"
  REDIS_PORT="6379"
  REDIS_ADMIN_PASS=""
  REDIS_INDEX_NAME="idx:canvas"
  REDIS_KEY_PREFIX="canvas:"
fi

run_cli() {
  if [ "$(docker inspect -f '{{.State.Running}}' agora-redis-primary 2>/dev/null || true)" = "true" ] \
    || [ "$(docker inspect -f '{{.State.Running}}' agora-redis-node 2>/dev/null || true)" = "true" ]; then
    "$SCRIPT_DIR/redis-ha-cli.sh" "$@"
  elif command -v redis-cli &> /dev/null; then
    REDISCLI_AUTH="$REDIS_ADMIN_PASS" redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" "$@"
  else
    docker exec -e REDISCLI_AUTH="$REDIS_ADMIN_PASS" agora-redis-stack redis-cli "$@"
  fi
}

if [ "$FORCE_CONFIRM" = false ]; then
  echo -e "${YELLOW}⚠️  [경고] Redis Stack 내 네임스페이스($REDIS_KEY_PREFIX*)의 모든 키가 삭제됩니다.${NC}"
  read -r -p "정말로 삭제하시겠습니까? [y/N]: " USER_INPUT
  if [[ ! "$USER_INPUT" =~ ^[yY]([eE][sS])?$ ]]; then
    echo "작업이 취소되었습니다."
    exit 0
  fi
fi

echo -e "${YELLOW}Redis Stack 데이터 삭제 중... ($REDIS_HOST:$REDIS_PORT)${NC}"

TOTAL_KEYS_BEFORE=$(run_cli DBSIZE 2>/dev/null | tr -dc '0-9' || echo "0")
echo "  - 삭제 전 전체 키 수: $TOTAL_KEYS_BEFORE 건"

DEL_LUA="local keys = redis.call('keys', ARGV[1]); if #keys > 0 then return redis.call('del', unpack(keys)) else return 0 end"
DELETED_KEYS=$(run_cli EVAL "$DEL_LUA" 0 "${REDIS_KEY_PREFIX}*" 2>/dev/null || echo "0")

if ! run_cli FT._LIST 2>/dev/null | grep -q "^${REDIS_INDEX_NAME}$"; then
  echo "  - RediSearch 인덱스($REDIS_INDEX_NAME) 재생성 중..."
  run_cli FT.CREATE "$REDIS_INDEX_NAME" ON JSON PREFIX 1 "$REDIS_KEY_PREFIX" SCHEMA \
      '$["canvas-name"]' AS canvas_name TEXT SORTABLE \
      '$["canvas-id"]' AS canvas_id NUMERIC SORTABLE \
      '$["admin-user-id"]' AS admin_user_id NUMERIC \
      '$.description' AS description TEXT \
      '$["canvas-password-hash"]' AS canvas_password_hash TAG \
      '$.people[*]' AS people NUMERIC \
      '$["init-group"]' AS init_group TAG > /dev/null 2>&1
  echo "  - [OK] RediSearch 인덱스($REDIS_INDEX_NAME) 스키마 복구 완료"
fi

TOTAL_KEYS_AFTER=$(run_cli DBSIZE 2>/dev/null | tr -dc '0-9' || echo "0")
echo -e "  [${GREEN}OK${NC}] Redis 키 ${DELETED_KEYS}건 삭제 완료 (현재 남은 전체 키: ${TOTAL_KEYS_AFTER}건)\n"
