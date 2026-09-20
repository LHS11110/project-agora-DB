#!/bin/bash
# ==============================================================================
# Agora Unified Storage Search & Inspection Script
# 모든 저장소(MS SQL, Elasticsearch, Redis Stack)의 현재 적재 데이터를 일괄 조회/검색합니다.
# ==============================================================================

set -e

CYAN='\033[0;36m'
GREEN='\033[0;32m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEARCH_KEYWORD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -q|--query)
      SEARCH_KEYWORD="$2"
      shift 2
      ;;
    -h|--help)
      echo -e "${BOLD}사용법:${NC} $0 [옵션]"
      echo ""
      echo "옵션:"
      echo "  -q, --query <키워드>   모든 저장소(MS SQL, Elasticsearch, Redis) 공통 키워드 검색"
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
echo -e "${CYAN}          Agora All Storages Data Inspection & Search           ${NC}"
echo -e "${CYAN}================================================================${NC}"
if [ -n "$SEARCH_KEYWORD" ]; then
  echo -e "  검색 키워드: \"$SEARCH_KEYWORD\" (모든 저장소 공통 적용)"
else
  echo -e "  조회 모드: 전체 데이터 대시보드 출력"
fi
echo -e "${CYAN}================================================================${NC}\n"

# 1. MS SQL 조회
if [ -f "$SCRIPT_DIR/mssql/search-mssql.sh" ]; then
  if [ -n "$SEARCH_KEYWORD" ]; then
    bash "$SCRIPT_DIR/mssql/search-mssql.sh" -q "$SEARCH_KEYWORD"
  else
    bash "$SCRIPT_DIR/mssql/search-mssql.sh"
  fi
fi

# 2. Elasticsearch 조회
if [ -f "$SCRIPT_DIR/elasticsearch/search-elasticsearch.sh" ]; then
  if [ -n "$SEARCH_KEYWORD" ]; then
    bash "$SCRIPT_DIR/elasticsearch/search-elasticsearch.sh" -q "$SEARCH_KEYWORD"
  else
    bash "$SCRIPT_DIR/elasticsearch/search-elasticsearch.sh"
  fi
fi

# 3. Redis Stack 조회
if [ -f "$SCRIPT_DIR/redis/search-redis.sh" ]; then
  if [ -n "$SEARCH_KEYWORD" ]; then
    bash "$SCRIPT_DIR/redis/search-redis.sh" -q "$SEARCH_KEYWORD"
  else
    bash "$SCRIPT_DIR/redis/search-redis.sh"
  fi
fi

echo -e "${CYAN}================================================================${NC}"
echo -e "${GREEN}[SUCCESS] 모든 저장소의 데이터 조회가 성공적으로 완료되었습니다!${NC}"
echo -e "${CYAN}================================================================${NC}\n"
