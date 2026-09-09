#!/bin/bash
# ==============================================================================
# Agora Redis -> MS SQL Registration Script
# redis/.env에 설정된 외부 접속 IP(REDIS_EXTERNAL_IP) 및 외부 포트(REDIS_EXTERNAL_PORT)를
# MS SQL Server의 redis_server 테이블에 등록하는 스크립트
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# 1. MS SQL 환경 변수 기본값 로드 (mssql/.env 우선 참조)
if [ -f "$ROOT_DIR/mssql/.env" ]; then
  MSSQL_ENV_HOST=$(grep -v '^#' "$ROOT_DIR/mssql/.env" | grep 'MSSQL_EXTERNAL_IP=' | cut -d '=' -f2- | tr -d '\r' || true)
  if [ -z "$MSSQL_ENV_HOST" ]; then
    MSSQL_ENV_HOST=$(grep -v '^#' "$ROOT_DIR/mssql/.env" | grep 'MSSQL_HOST=' | cut -d '=' -f2- | tr -d '\r' || true)
  fi
  MSSQL_ENV_PORT=$(grep -v '^#' "$ROOT_DIR/mssql/.env" | grep 'MSSQL_EXTERNAL_PORT=' | cut -d '=' -f2- | tr -d '\r' || true)
  if [ -z "$MSSQL_ENV_PORT" ]; then
    MSSQL_ENV_PORT=$(grep -v '^#' "$ROOT_DIR/mssql/.env" | grep 'MSSQL_PORT=' | cut -d '=' -f2- | tr -d '\r' || true)
  fi
  MSSQL_ENV_DB=$(grep -v '^#' "$ROOT_DIR/mssql/.env" | grep 'MSSQL_DB=' | cut -d '=' -f2- | tr -d '\r' || true)
  MSSQL_ENV_USER=$(grep -v '^#' "$ROOT_DIR/mssql/.env" | grep 'MSSQL_USER=' | cut -d '=' -f2- | tr -d '\r' || true)
  MSSQL_ENV_PASS=$(grep -v '^#' "$ROOT_DIR/mssql/.env" | grep 'MSSQL_PASSWORD=' | cut -d '=' -f2- | tr -d '\r' || true)
  MSSQL_ENV_TABLE=$(grep -v '^#' "$ROOT_DIR/mssql/.env" | grep 'MSSQL_TABLE_REDIS_SERVER=' | cut -d '=' -f2- | tr -d '\r' || true)
fi

# 2. Redis 환경 변수 로드 (redis/.env)
if [ -f "$SCRIPT_DIR/.env" ]; then
  export $(grep -v '^#' "$SCRIPT_DIR/.env" | xargs)
elif [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

# 3. 접속 및 등록 변수 확정
REDIS_IP="${REDIS_EXTERNAL_IP:-127.0.0.1}"
REDIS_EXT_PORT="${REDIS_EXTERNAL_PORT:-${REDIS_PORT:-6379}}"

MSSQL_RAW_HOST="${MSSQL_HOST:-${MSSQL_ENV_HOST:-127.0.0.1}}"
if [ "$MSSQL_RAW_HOST" = "0.0.0.0" ]; then
  MSSQL_HOST="127.0.0.1"
else
  MSSQL_HOST="$MSSQL_RAW_HOST"
fi
MSSQL_PORT="${MSSQL_PORT:-${MSSQL_ENV_PORT:-1433}}"
MSSQL_DB="${MSSQL_DB:-${MSSQL_ENV_DB:-agora_db}}"
MSSQL_USER="${MSSQL_USER:-${MSSQL_ENV_USER:-agora_user}}"
MSSQL_PASS="${MSSQL_PASSWORD:-${MSSQL_ENV_PASS:-AgoraUserSecret@Passw0rd!2026}}"
MSSQL_TABLE="${MSSQL_TABLE_REDIS_SERVER:-${MSSQL_ENV_TABLE:-redis_server}}"

echo "=================================================================="
echo "  Agora Redis -> MS SQL External Endpoint Registration"
echo "=================================================================="
echo "  - 등록 대상 Redis 외부 IP:   $REDIS_IP"
echo "  - 등록 대상 Redis 외부 포트: $REDIS_EXT_PORT"
echo "  - 대상 MS SQL 서버:          $MSSQL_HOST:$MSSQL_PORT ($MSSQL_DB)"
echo "  - 대상 테이블:               $MSSQL_TABLE"
echo "=================================================================="

# 4. sqlcmd 실행 래퍼 함수 (로컬 sqlcmd 우선, 없으면 docker exec fallback)
run_mssql_cmd() {
  local sql_query="$1"
  if command -v sqlcmd &> /dev/null; then
    sqlcmd -S "$MSSQL_HOST,$MSSQL_PORT" -U "$MSSQL_USER" -P "$MSSQL_PASS" -C -I -d "$MSSQL_DB" -Q "$sql_query" -W
  else
    docker exec agora-mssql /opt/mssql-tools18/bin/sqlcmd \
      -S localhost -U "$MSSQL_USER" -P "$MSSQL_PASS" -C -I -d "$MSSQL_DB" -Q "$sql_query" -W
  fi
}

# 5. MS SQL 접속 및 테이블 존재 여부 사전 확인
TABLE_CHECK_SQL="SET NOCOUNT ON; SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = '$MSSQL_TABLE';"
if ! TABLE_EXISTS=$(run_mssql_cmd "$TABLE_CHECK_SQL" 2>&1); then
  echo -e "\n[ERROR] MS SQL 접속 실패 또는 쿼리 실행 실패:"
  echo "$TABLE_EXISTS"
  echo -e "\n[TIP] MS SQL 컨테이너(agora-mssql)가 실행 중이며 ./mssql/init-mssql.sh 로 초기화되었는지 확인하세요."
  exit 1
fi

TABLE_COUNT=$(echo "$TABLE_EXISTS" | tr -dc '0-9')
if [ "$TABLE_COUNT" != "1" ]; then
  echo -e "\n[ERROR] 대상 테이블 [$MSSQL_TABLE] 이 데이터베이스 [$MSSQL_DB] 에 존재하지 않습니다."
  echo "[TIP] ./mssql/init-mssql.sh 를 먼저 실행하여 테이블 스키마를 생성해주세요."
  exit 1
fi

# 6. 중복 방지(Idempotent) 등록 쿼리 수행
REGISTER_SQL=$(cat <<EOF
SET NOCOUNT ON;
IF NOT EXISTS (
    SELECT 1 FROM [$MSSQL_TABLE]
    WHERE redis_ip = '$REDIS_IP' AND redis_port = '$REDIS_EXT_PORT'
)
BEGIN
    INSERT INTO [$MSSQL_TABLE] (redis_ip, redis_port)
    VALUES ('$REDIS_IP', '$REDIS_EXT_PORT');
    SELECT 'SUCCESS_INSERTED' AS [result_status];
END
ELSE
BEGIN
    SELECT 'ALREADY_EXISTS' AS [result_status];
END
EOF
)

RESULT_OUT=$(run_mssql_cmd "$REGISTER_SQL" 2>&1)

if echo "$RESULT_OUT" | grep -q "SUCCESS_INSERTED"; then
  echo -e "\n[OK] 신규 Redis 서버가 MS SQL [$MSSQL_TABLE] 테이블에 성공적으로 등록되었습니다!"
  echo "     (redis_ip: $REDIS_IP, redis_port: $REDIS_EXT_PORT)"
elif echo "$RESULT_OUT" | grep -q "ALREADY_EXISTS"; then
  echo -e "\n[INFO] 해당 Redis 서버($REDIS_IP:$REDIS_EXT_PORT)는 이미 MS SQL [$MSSQL_TABLE] 테이블에 등록되어 있습니다."
else
  echo -e "\n[ERROR] Redis 서버 등록 중 예기치 않은 응답이 발생했습니다:"
  echo "$RESULT_OUT"
  exit 1
fi

# 7. 현재 등록된 Redis 서버 목록 출력
echo -e "\n=== 현재 MS SQL [$MSSQL_TABLE] 에 등록된 Redis 서버 목록 ==="
LIST_SQL="SELECT redis_id, redis_ip, redis_port, created_at FROM [$MSSQL_TABLE];"
run_mssql_cmd "$LIST_SQL"

echo -e "\n[SUCCESS] Redis 외부 접속 정보의 MS SQL 등록 작업이 완료되었습니다.\n"
