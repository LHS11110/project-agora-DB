#!/bin/bash
# ==============================================================================
# Agora Storage Batch Data Cleanup Script
# 현재 실행 중인 모든 저장소(MS SQL, Elasticsearch, Redis Stack)의 데이터를
# 스키마 및 인덱스 구조 손상 없이 일괄적으로 안전하게 초기화(삭제)합니다.
# ==============================================================================

set -e

# 색상 정의
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"

FORCE_CONFIRM=false
RE_REGISTER_REDIS=true

# 파라미터 파싱
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes|--force)
      FORCE_CONFIRM=true
      shift
      ;;
    --no-re-register)
      RE_REGISTER_REDIS=false
      shift
      ;;
    -h|--help)
      echo -e "${BOLD}사용법:${NC} $0 [옵션]"
      echo ""
      echo "옵션:"
      echo "  -y, --yes, --force   확인 프롬프트를 건너뛰고 즉시 삭제를 진행합니다 (CI/자동화용)"
      echo "  --no-re-register     MS SQL 데이터 삭제 후 Redis 서버(redis_server) 자동 재등록을 건너뜁니다"
      echo "  -h, --help           도움말을 출력합니다"
      echo ""
      exit 0
      ;;
    *)
      echo -e "${RED}[오류] 알 수 없는 옵션: $1${NC}"
      echo "도움말 확인: $0 --help"
      exit 1
      ;;
  esac
done

echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN}        Agora Storage Batch Data Cleanup (데이터 일괄 삭제)     ${NC}"
echo -e "${CYAN}================================================================${NC}"
echo -e "대상 저장소:"
echo -e "  1. MS SQL Server (회원, 세션, 캔버스 메타데이터, 서버 등록 테이블)"
echo -e "  2. Elasticsearch (캔버스 문서 및 인덱스 내 데이터)"
echo -e "  3. Redis Stack   (RedisJSON 캔버스 캐시 및 RediSearch 데이터)"
echo -e "${CYAN}================================================================${NC}\n"

# 대화형 확인 프롬프트
if [ "$FORCE_CONFIRM" = false ]; then
  echo -e "${YELLOW}⚠️  [경고] 모든 저장소의 레코드 및 문서가 완전히 삭제됩니다.${NC}"
  echo -e "   (테이블 스키마, 제약조건, RediSearch/ES 매핑 구조는 보존됩니다)"
  read -r -p "정말로 일괄 삭제를 진행하시겠습니까? [y/N]: " USER_INPUT
  if [[ ! "$USER_INPUT" =~ ^[yY]([eE][sS])?$ ]]; then
    echo -e "\n${YELLOW}[INFO] 사용자에 의해 데이터 삭제 작업이 취소되었습니다.${NC}\n"
    exit 0
  fi
  echo ""
fi

# ==============================================================================
# 저장소별 전용 스크립트 순차 실행
# ==============================================================================

# 1. MS SQL 데이터 삭제
if [ -f "$ROOT_DIR/mssql/clean-mssql.sh" ]; then
  echo -e "${YELLOW}[1/3] MS SQL Server 데이터 삭제...${NC}"
  MSSQL_ARGS=("-y")
  if [ "$RE_REGISTER_REDIS" = false ]; then
    MSSQL_ARGS+=("--no-re-register")
  fi
  bash "$ROOT_DIR/mssql/clean-mssql.sh" "${MSSQL_ARGS[@]}"
else
  echo -e "${RED}[WARN] $ROOT_DIR/mssql/clean-mssql.sh 를 찾을 수 없습니다.${NC}"
fi

# 2. Elasticsearch 데이터 삭제
if [ -f "$ROOT_DIR/elasticsearch/clean-elasticsearch.sh" ]; then
  echo -e "${YELLOW}[2/3] Elasticsearch 데이터 삭제...${NC}"
  bash "$ROOT_DIR/elasticsearch/clean-elasticsearch.sh" -y
else
  echo -e "${RED}[WARN] $ROOT_DIR/elasticsearch/clean-elasticsearch.sh 를 찾을 수 없습니다.${NC}"
fi

# 3. Redis Stack 데이터 삭제
if [ -f "$ROOT_DIR/redis/clean-redis.sh" ]; then
  echo -e "${YELLOW}[3/3] Redis Stack 데이터 삭제...${NC}"
  bash "$ROOT_DIR/redis/clean-redis.sh" -y
else
  echo -e "${RED}[WARN] $ROOT_DIR/redis/clean-redis.sh 를 찾을 수 없습니다.${NC}"
fi

echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN}              저장소 데이터 일괄 삭제 작업 완료                 ${NC}"
echo -e "${CYAN}================================================================${NC}"
echo -e "  - MS SQL Server : 회원/세션/캔버스 데이터 삭제 및 IDENTITY 리셋 완료"
if [ "$RE_REGISTER_REDIS" = true ]; then
  echo -e "                    (Redis 엔드포인트 정상 재등록 유지)"
fi
echo -e "  - Elasticsearch : 인덱스 도큐먼트 전체 삭제 (매핑 유지)"
echo -e "  - Redis Stack   : 캔버스 키 전체 삭제 (RediSearch 인덱스 유지)"
echo -e "${CYAN}================================================================${NC}"
echo -e "${GREEN}[SUCCESS] 모든 저장소가 깨끗한 초기 상태로 초기화되었습니다!${NC}\n"
