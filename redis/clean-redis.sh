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

ENV_FILE="$SCRIPT_DIR/.env"
[ -f "$ENV_FILE" ] || { echo "Redis HA environment file not found: $ENV_FILE" >&2; exit 1; }
read_env() { sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1 | tr -d '\r'; }
REDIS_INDEX_NAME="$(read_env REDIS_INDEX_NAME)"
REDIS_INDEX_NAME="${REDIS_INDEX_NAME:-idx:canvas}"
REDIS_KEY_PREFIX="$(read_env REDIS_KEY_PREFIX)"
REDIS_KEY_PREFIX="${REDIS_KEY_PREFIX:-canvas:}"
REDIS_HOST="Sentinel HA"
REDIS_PORT="primary:6379"

run_cli() {
  "$SCRIPT_DIR/redis-ha-cli.sh" "$@"
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
