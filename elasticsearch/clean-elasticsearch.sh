#!/bin/bash
# ==============================================================================
# Agora Elasticsearch Document Cleanup Script
# Elasticsearch (canvas 인덱스) 전용 도큐먼트 초기화 스크립트
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
else
  ES_IP="127.0.0.1"
  ES_PORT="9200"
  ES_INDEX="canvas"
  ES_USER="agora_user"
  ES_PASS=""
fi
ES_URL="http://$ES_IP:$ES_PORT"

if [ "$FORCE_CONFIRM" = false ]; then
  echo -e "${YELLOW}⚠️  [경고] Elasticsearch ($ES_INDEX 인덱스)의 모든 도큐먼트가 삭제됩니다.${NC}"
  read -r -p "정말로 삭제하시겠습니까? [y/N]: " USER_INPUT
  if [[ ! "$USER_INPUT" =~ ^[yY]([eE][sS])?$ ]]; then
    echo "작업이 취소되었습니다."
    exit 0
  fi
fi

echo -e "${YELLOW}Elasticsearch 데이터 삭제 중... ($ES_USER@$ES_URL, 인덱스: $ES_INDEX)${NC}"

DOC_CNT_BEFORE=$(curl -s -u "$ES_USER:$ES_PASS" "$ES_URL/$ES_INDEX/_count" | grep -o '"count":[0-9]*' | cut -d':' -f2 || echo "0")
echo "  - 삭제 전 도큐먼트 수: $DOC_CNT_BEFORE 건"

ES_DEL_RESP=$(curl -s -u "$ES_USER:$ES_PASS" -X POST "$ES_URL/$ES_INDEX/_delete_by_query?conflicts=proceed&refresh=true" \
  -H 'Content-Type: application/json' \
  -d '{"query": {"match_all": {}}}')

DOC_CNT_AFTER=$(curl -s -u "$ES_USER:$ES_PASS" "$ES_URL/$ES_INDEX/_count" | grep -o '"count":[0-9]*' | cut -d':' -f2 || echo "0")
DELETED_CNT=$(echo "$ES_DEL_RESP" | grep -o '"deleted":[0-9]*' | cut -d':' -f2 || echo "$DOC_CNT_BEFORE")

echo -e "  [${GREEN}OK${NC}] Elasticsearch 인덱스($ES_INDEX) 도큐먼트 $DELETED_CNT건 삭제 완료 (현재 도큐먼트: $DOC_CNT_AFTER 건)\n"
