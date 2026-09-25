#!/bin/bash
# ==============================================================================
# Agora Elasticsearch Document Inspection & Search Script
# Elasticsearch (canvas 인덱스)에 저장된 도큐먼트 조회 및 전문 검색 스크립트
# ==============================================================================

set -e
set -o pipefail

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ES_HOST_OVERRIDE="${ES_TEST_HOST:-${ES_HOST:-}}"
ES_PORT_OVERRIDE="${ES_TEST_PORT:-${ES_PORT:-}}"
ES_SCHEME_OVERRIDE="${ES_SCHEME:-}"
ES_TLS_OVERRIDE="${ES_HTTP_TLS_ENABLED:-}"
ES_CA_CERT_OVERRIDE="${ES_CA_CERT:-}"

# .env 로드
if [ -f "$SCRIPT_DIR/.env" ]; then
  ENV_FILE="$SCRIPT_DIR/.env"
elif [ -f "$ROOT_DIR/elasticsearch/.env" ]; then
  ENV_FILE="$ROOT_DIR/elasticsearch/.env"
else
  ENV_FILE=""
fi

if [ -n "$ENV_FILE" ]; then
  ES_RAW_IP=$(grep -v '^#' "$ENV_FILE" | grep 'ES_EXTERNAL_IP=' | cut -d '=' -f2- | tr -d '\r' || echo "127.0.0.1")
  ES_IP="127.0.0.1"
  if [ "$ES_RAW_IP" != "0.0.0.0" ] && [ -n "$ES_RAW_IP" ]; then
    ES_IP="$ES_RAW_IP"
  fi
  ES_PORT=$(grep -v '^#' "$ENV_FILE" | grep 'ES_EXTERNAL_PORT=' | cut -d '=' -f2- | tr -d '\r' || echo "9200")
  ES_INDEX=$(grep -v '^#' "$ENV_FILE" | grep 'ES_INDEX=' | cut -d '=' -f2- | tr -d '\r' || echo "canvas")
  ES_USER=$(grep -v '^#' "$ENV_FILE" | grep 'ES_USER_NAME=' | cut -d '=' -f2- | tr -d '\r' || echo "agora_user")
  ES_PASS=$(grep -v '^#' "$ENV_FILE" | grep 'ES_USER_PASSWORD=' | cut -d '=' -f2- | tr -d '\r' || echo "")
  ES_SCHEME=$(grep -v '^#' "$ENV_FILE" | grep '^ES_SCHEME=' | cut -d '=' -f2- | tr -d '\r' || true)
  ES_HTTP_TLS_ENABLED=$(grep -v '^#' "$ENV_FILE" | grep '^ES_HTTP_TLS_ENABLED=' | cut -d '=' -f2- | tr -d '\r' || echo "false")
  ES_CA_CERT=$(grep -v '^#' "$ENV_FILE" | grep '^ES_CA_CERT=' | cut -d '=' -f2- | tr -d '\r' || true)
else
  ES_IP="127.0.0.1"
  ES_PORT="9200"
  ES_INDEX="canvas"
  ES_USER="agora_user"
  ES_PASS=""
  ES_SCHEME=""
  ES_HTTP_TLS_ENABLED="false"
  ES_CA_CERT=""
fi

if [ -n "$ES_HOST_OVERRIDE" ]; then ES_IP="$ES_HOST_OVERRIDE"; fi
if [ -n "$ES_PORT_OVERRIDE" ]; then ES_PORT="$ES_PORT_OVERRIDE"; fi
if [ -n "$ES_SCHEME_OVERRIDE" ]; then ES_SCHEME="$ES_SCHEME_OVERRIDE"; fi
if [ -n "$ES_TLS_OVERRIDE" ]; then ES_HTTP_TLS_ENABLED="$ES_TLS_OVERRIDE"; fi
if [ -n "$ES_CA_CERT_OVERRIDE" ]; then ES_CA_CERT="$ES_CA_CERT_OVERRIDE"; fi
if [ -z "$ES_SCHEME" ]; then
  if [ "$ES_HTTP_TLS_ENABLED" = "true" ]; then ES_SCHEME="https"; else ES_SCHEME="http"; fi
fi
if [ "$ES_SCHEME" != "http" ] && [ "$ES_SCHEME" != "https" ]; then
  echo "[ERROR] ES_SCHEME must be http or https." >&2
  exit 1
fi
if [ "$ES_HTTP_TLS_ENABLED" = "true" ] && [ "$ES_SCHEME" != "https" ]; then
  echo "[ERROR] ES_HTTP_TLS_ENABLED=true requires ES_SCHEME=https." >&2
  exit 1
fi
ES_URL="$ES_SCHEME://$ES_IP:$ES_PORT"
CURL_TLS_ARGS=()
if [ -n "$ES_CA_CERT" ]; then CURL_TLS_ARGS+=(--cacert "$ES_CA_CERT"); fi
curl_es() { curl -fsS "${CURL_TLS_ARGS[@]}" "$@"; }

SEARCH_KEYWORD=""
DOC_ID=""
SIZE=20

while [[ $# -gt 0 ]]; do
  case "$1" in
    -q|--query)
      SEARCH_KEYWORD="$2"
      shift 2
      ;;
    -i|--id)
      DOC_ID="$2"
      shift 2
      ;;
    -s|--size)
      SIZE="$2"
      shift 2
      ;;
    -h|--help)
      echo -e "${BOLD}사용법:${NC} $0 [옵션]"
      echo ""
      echo "옵션:"
      echo "  -q, --query <키워드>   도큐먼트 전문 검색 (canvas-name, description 등)"
      echo "  -i, --id <문서ID>      특정 도큐먼트 ID 단건 조회"
      echo "  -s, --size <개수>      조회할 최대 도큐먼트 수 (기본값: 20)"
      echo "  -h, --help             도움말 출력"
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
echo -e "${CYAN}             Elasticsearch 도큐먼트 조회 및 검색                ${NC}"
echo -e "${CYAN}================================================================${NC}"
echo -e "  - 접속 대상: $ES_USER@$ES_URL (인덱스: $ES_INDEX)"
if [ -n "$DOC_ID" ]; then
  echo -e "  - 단건 조회 대상 ID: $DOC_ID"
elif [ -n "$SEARCH_KEYWORD" ]; then
  echo -e "  - 검색 키워드: \"$SEARCH_KEYWORD\""
fi
echo -e "${CYAN}================================================================${NC}\n"

# 1. 인덱스 존재 및 도큐먼트 수 확인
TOTAL_DOCS=$(curl_es -u "$ES_USER:$ES_PASS" "$ES_URL/$ES_INDEX/_count" | grep -o '"count":[0-9]*' | cut -d':' -f2)
echo -e "${YELLOW}▶ 인덱스 상태: [$ES_INDEX]${NC}"
echo -e "  총 도큐먼트 수: ${BOLD}$TOTAL_DOCS${NC} 건\n"

if [ "$TOTAL_DOCS" -eq 0 ] && [ -z "$DOC_ID" ]; then
  echo -e "  ${YELLOW}(인덱스에 저장된 도큐먼트가 없습니다)${NC}\n"
  exit 0
fi

# 2. 단건 조회 (-i 옵션)
if [ -n "$DOC_ID" ]; then
  echo -e "${YELLOW}▶ 도큐먼트 단건 조회: ID [$DOC_ID]${NC}"
  RESP=$(curl_es -u "$ES_USER:$ES_PASS" "$ES_URL/$ES_INDEX/_doc/$DOC_ID")
  if echo "$RESP" | grep -q '"found":true'; then
    echo "$RESP" | python3 -m json.tool 2>/dev/null || echo "$RESP"
  else
    echo -e "  ${RED}[NOT FOUND] ID '$DOC_ID' 에 해당하는 도큐먼트를 찾을 수 없습니다.${NC}"
  fi
  echo ""
  exit 0
fi

# 3. 검색 쿼리 실행
if [ -n "$SEARCH_KEYWORD" ]; then
  echo -e "${YELLOW}▶ 키워드 검색 결과 (키워드: '$SEARCH_KEYWORD', 최대: $SIZE 건)${NC}"
  SEARCH_PAYLOAD=$(cat <<EOF
{
  "size": $SIZE,
  "query": {
    "multi_match": {
      "query": "$SEARCH_KEYWORD",
      "fields": ["canvas-name^2", "description", "init-group", "canvas-password-hash"]
    }
  }
}
EOF
)
else
  echo -e "${YELLOW}▶ 전체 도큐먼트 목록 (최대: $SIZE 건)${NC}"
  SEARCH_PAYLOAD=$(cat <<EOF
{
  "size": $SIZE,
  "query": {
    "match_all": {}
  }
}
EOF
)
fi

RESP=$(curl_es -u "$ES_USER:$ES_PASS" -X POST "$ES_URL/$ES_INDEX/_search" \
  -H 'Content-Type: application/json' \
  -d "$SEARCH_PAYLOAD")

HITS_COUNT=$(echo "$RESP" | grep -o '"value":[0-9]*' | head -n 1 | cut -d':' -f2 || echo "0")
echo -e "  검색 일치 도큐먼트 수: ${BOLD}$HITS_COUNT${NC} 건\n"

if [ "$HITS_COUNT" -gt 0 ]; then
  echo "$RESP" | python3 -c '
import sys, json

try:
    data = json.load(sys.stdin)
    hits = data.get("hits", {}).get("hits", [])
    for idx, hit in enumerate(hits, 1):
        doc_id = hit.get("_id")
        score = hit.get("_score")
        src = hit.get("_source", {})
        cid = src.get("canvas-id", "N/A")
        name = src.get("canvas-name", "N/A")
        uid = src.get("admin-user-id", "N/A")
        desc = src.get("description", "")
        pwd = src.get("canvas-password-hash", "")
        pwd_type = "비공개(Hash존재)" if pwd else "공개(Public)"
        people = src.get("people", [])
        init_group = src.get("init-group", "N/A")

        print(f"  [{idx}] Document ID: {doc_id} (Score: {score})")
        print(f"      • Canvas ID:     {cid}")
        print(f"      • Canvas Name:   {name}")
        print(f"      • Admin User ID: {uid}")
        print(f"      • Type:          {pwd_type}")
        print(f"      • Description:   {desc}")
        print(f"      • People ({len(people)}명):   {people}")
        print(f"      • Init Group:    {init_group}")
        print("      " + "-" * 50)
except Exception as e:
    print("출력 처리 실패:", e)
'
else
  echo -e "  ${YELLOW}일치하는 도큐먼트가 없습니다.${NC}"
fi

echo -e "\n${GREEN}[OK] Elasticsearch 조회가 완료되었습니다.${NC}\n"
