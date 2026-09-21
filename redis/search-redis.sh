#!/bin/bash
# ==============================================================================
# Agora Redis Stack Key & Data Inspection Script
# Redis Stack (RedisJSON + RediSearch) 키 및 JSON 데이터 조회/검색 스크립트
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

# .env 로드
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
  REDIS_USER=$(grep -v '^#' "$ENV_FILE" | grep 'REDIS_USER=' | cut -d '=' -f2- | tr -d '\r' || echo "agora_user")
  REDIS_USER_PASS=$(grep -v '^#' "$ENV_FILE" | grep 'REDIS_USER_PASSWORD=' | cut -d '=' -f2- | tr -d '\r' || echo "")
  REDIS_INDEX_NAME=$(grep -v '^#' "$ENV_FILE" | grep 'REDIS_INDEX_NAME=' | cut -d '=' -f2- | tr -d '\r' || echo "idx:canvas")
  REDIS_KEY_PREFIX=$(grep -v '^#' "$ENV_FILE" | grep 'REDIS_KEY_PREFIX=' | cut -d '=' -f2- | tr -d '\r' || echo "canvas:")
else
  REDIS_HOST="127.0.0.1"
  REDIS_PORT="6379"
  REDIS_ADMIN_PASS=""
  REDIS_USER="agora_user"
  REDIS_USER_PASS=""
  REDIS_INDEX_NAME="idx:canvas"
  REDIS_KEY_PREFIX="canvas:"
fi

run_cli() {
  if command -v redis-cli &> /dev/null; then
    REDISCLI_AUTH="$REDIS_ADMIN_PASS" redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" "$@"
  else
    docker exec -e REDISCLI_AUTH="$REDIS_ADMIN_PASS" agora-redis-stack redis-cli "$@"
  fi
}

KEY_PATTERN="${REDIS_KEY_PREFIX}*"
SEARCH_QUERY=""
SPECIFIC_KEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--pattern)
      KEY_PATTERN="$2"
      shift 2
      ;;
    -q|--query)
      SEARCH_QUERY="$2"
      shift 2
      ;;
    -k|--key)
      SPECIFIC_KEY="$2"
      shift 2
      ;;
    -h|--help)
      echo -e "${BOLD}사용법:${NC} $0 [옵션]"
      echo ""
      echo "옵션:"
      echo "  -p, --pattern <패턴>   키 스캔 패턴 (기본값: canvas:*)"
      echo "  -q, --query <쿼리>     RediSearch 전문 검색 (예: '@admin_user_id:[1 100]' 또는 'test')"
      echo "  -k, --key <키이름>     특정 단일 키 상세 조회"
      echo "  -h, --help             도움말 출력"
      echo ""
      exit 0
      ;;
    *)
      SEARCH_QUERY="$1"
      shift
      ;;
  esac
done

echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN}             Redis Stack 키 및 JSON 데이터 조회                 ${NC}"
echo -e "${CYAN}================================================================${NC}"
echo -e "  - 접속 대상: $REDIS_USER@$REDIS_HOST:$REDIS_PORT"
echo -e "  - 인덱스: $REDIS_INDEX_NAME, 키 네임스페이스: $REDIS_KEY_PREFIX"
if [ -n "$SPECIFIC_KEY" ]; then
  echo -e "  - 조회 키: $SPECIFIC_KEY"
elif [ -n "$SEARCH_QUERY" ]; then
  echo -e "  - RediSearch 검색 쿼리: \"$SEARCH_QUERY\""
else
  echo -e "  - 검색 패턴: \"$KEY_PATTERN\""
fi
echo -e "${CYAN}================================================================${NC}\n"

# 1. 인덱스 및 DB 상태
TOTAL_KEYS=$(run_cli DBSIZE 2>/dev/null | tr -dc '0-9' || echo "0")
INDEX_DOCS="0"
if run_cli FT._LIST 2>/dev/null | grep -q "^${REDIS_INDEX_NAME}$"; then
  INDEX_DOCS=$(run_cli FT.INFO "$REDIS_INDEX_NAME" 2>/dev/null | grep -A 1 "num_docs" | tail -n 1 | tr -dc '0-9' || echo "0")
fi

echo -e "${YELLOW}▶ Redis Stack 상태${NC}"
echo -e "  전체 키 개수:          ${BOLD}$TOTAL_KEYS${NC} 건"
echo -e "  RediSearch 인덱스 문서: ${BOLD}$INDEX_DOCS${NC} 건 ($REDIS_INDEX_NAME)\n"

# 2. 단일 키 상세 조회 (-k)
if [ -n "$SPECIFIC_KEY" ]; then
  echo -e "${YELLOW}▶ 단일 키 상세 조회: [$SPECIFIC_KEY]${NC}"
  KEY_EXISTS=$(run_cli EXISTS "$SPECIFIC_KEY" 2>/dev/null | tr -dc '0-9')
  if [ "$KEY_EXISTS" = "1" ]; then
    K_TYPE=$(run_cli TYPE "$SPECIFIC_KEY" 2>/dev/null | tr -d '[:space:]')
    K_TTL=$(run_cli TTL "$SPECIFIC_KEY" 2>/dev/null | tr -d '[:space:]')
    echo "  • Key Type: $K_TYPE"
    echo "  • TTL:      ${K_TTL}s"
    if [ "$K_TYPE" = "ReJSON-RL" ] || [ "$K_TYPE" = "json" ]; then
      VAL=$(run_cli JSON.GET "$SPECIFIC_KEY" 2>/dev/null || echo "")
      echo "  • JSON Payload:"
      echo "$VAL" | python3 -m json.tool 2>/dev/null | sed 's/^/      /' || echo "      $VAL"
    else
      VAL=$(run_cli GET "$SPECIFIC_KEY" 2>/dev/null || echo "")
      echo "  • Value: $VAL"
    fi
  else
    echo -e "  ${RED}[NOT FOUND] 키 '$SPECIFIC_KEY' 가 존재하지 않습니다.${NC}"
  fi
  echo ""
  exit 0
fi

# 3. RediSearch 검색 (-q)
if [ -n "$SEARCH_QUERY" ]; then
  echo -e "${YELLOW}▶ RediSearch 검색: FT.SEARCH $REDIS_INDEX_NAME \"$SEARCH_QUERY\"${NC}"
  SEARCH_RES=$(run_cli FT.SEARCH "$REDIS_INDEX_NAME" "$SEARCH_QUERY" 2>/dev/null || true)
  if echo "$SEARCH_RES" | grep -q "Unknown index"; then
    echo -e "  ${RED}[ERROR] 인덱스 $REDIS_INDEX_NAME 가 존재하지 않습니다.${NC}\n"
    exit 1
  fi

  MATCH_CNT=$(echo "$SEARCH_RES" | head -n 1 | tr -dc '0-9' || echo "0")
  echo -e "  일치한 도큐먼트 수: ${BOLD}$MATCH_CNT${NC} 건\n"

  if [ "$MATCH_CNT" -gt 0 ]; then
    echo "$SEARCH_RES" | sed 's/^/  /'
  else
    echo -e "  ${YELLOW}일치하는 검색 결과가 없습니다.${NC}"
  fi
  echo ""
  exit 0
fi

# 4. 전체 키 목록 및 JSON 데이터 조회
echo -e "${YELLOW}▶ 패턴 매칭 키 및 데이터 목록 (패턴: '$KEY_PATTERN')${NC}"

# KEYS 또는 SCAN으로 키 목록 추출
MATCHED_KEYS=$(run_cli KEYS "$KEY_PATTERN" 2>/dev/null | tr '\r' '\n' | grep -v '^\s*$' || true)

if [ -z "$MATCHED_KEYS" ]; then
  echo -e "  ${YELLOW}패턴('$KEY_PATTERN')에 해당하는 키가 없습니다.${NC}\n"
  exit 0
fi

KEY_COUNT=$(echo "$MATCHED_KEYS" | wc -l)
echo -e "  발견된 키 개수: ${BOLD}$KEY_COUNT${NC} 건\n"

IDX=1
while IFS= read -r key; do
  [ -z "$key" ] && continue
  K_TYPE=$(run_cli TYPE "$key" 2>/dev/null | tr -d '[:space:]')
  K_TTL=$(run_cli TTL "$key" 2>/dev/null | tr -d '[:space:]')

  echo -e "  [$IDX] ${BOLD}$key${NC} (Type: $K_TYPE, TTL: ${K_TTL}s)"
  if [ "$K_TYPE" = "ReJSON-RL" ] || [ "$K_TYPE" = "json" ]; then
    VAL=$(run_cli JSON.GET "$key" 2>/dev/null || echo "")
    echo "$VAL" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    cid = data.get("canvas-id", "N/A")
    name = data.get("canvas-name", "N/A")
    uid = data.get("admin-user-id", "N/A")
    desc = data.get("description", "")
    pwd = data.get("canvas-password-hash", "")
    pwd_type = "비공개(Hash존재)" if pwd else "공개(Public)"
    people = data.get("people", [])
    init_group = data.get("init-group", "N/A")

    print(f"      • Canvas ID:     {cid}")
    print(f"      • Canvas Name:   {name}")
    print(f"      • Admin User ID: {uid}")
    print(f"      • Type:          {pwd_type}")
    print(f"      • Description:   {desc}")
    print(f"      • People ({len(people)}명):   {people}")
    print(f"      • Init Group:    {init_group}")
except Exception:
    print("      • Payload:", sys.stdin.read().strip())
'
  else
    VAL=$(run_cli GET "$key" 2>/dev/null || echo "")
    echo "      • Value: $VAL"
  fi
  echo "      --------------------------------------------------"
  IDX=$((IDX + 1))
done <<< "$MATCHED_KEYS"

echo -e "\n${GREEN}[OK] Redis Stack 조회가 완료되었습니다.${NC}\n"
