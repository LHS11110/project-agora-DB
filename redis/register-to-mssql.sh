#!/bin/bash
# ==============================================================================
# Agora Redis -> MS SQL Registration Script
# redis/.env에 설정된 Redis HA primary 사설 주소를 SQL의 단일 논리 서비스 행으로 등록합니다.
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DB_ENCRYPT_OVERRIDE="${DB_ENCRYPT:-}"
DB_TRUST_CERT_OVERRIDE="${DB_TRUST_SERVER_CERTIFICATE:-}"
MSSQL_TLS_OVERRIDE="${MSSQL_TLS_ENABLED:-}"

# 1. MS SQL 환경 변수 기본값 로드 (mssql/.env 우선 참조)
if [ -f "$ROOT_DIR/mssql/.env" ]; then
  MSSQL_ENV_CA_FILE=$(source "$ROOT_DIR/mssql/.env"; printf '%s' "${SSL_CERT_FILE:-${MSSQL_TLS_CERTS_DIR:-$ROOT_DIR/mssql/tls}/ca.crt}")
  MSSQL_ENV_HOST=$(grep -v '^#' "$ROOT_DIR/mssql/.env" | grep '^MSSQL_MANAGEMENT_HOST=' | cut -d '=' -f2- | tr -d '\r' || true)
  if [ -z "$MSSQL_ENV_HOST" ]; then
    MSSQL_ENV_HOST=$(grep -v '^#' "$ROOT_DIR/mssql/.env" | grep '^MSSQL_EXTERNAL_IP=' | cut -d '=' -f2- | tr -d '\r' || true)
  fi
  if [ -z "$MSSQL_ENV_HOST" ]; then
    MSSQL_ENV_HOST=$(grep -v '^#' "$ROOT_DIR/mssql/.env" | grep 'MSSQL_HOST=' | cut -d '=' -f2- | tr -d '\r' || true)
  fi
  MSSQL_ENV_PORT=$(grep -v '^#' "$ROOT_DIR/mssql/.env" | grep '^MSSQL_MANAGEMENT_PORT=' | cut -d '=' -f2- | tr -d '\r' || true)
  if [ -z "$MSSQL_ENV_PORT" ]; then
    MSSQL_ENV_PORT=$(grep -v '^#' "$ROOT_DIR/mssql/.env" | grep '^MSSQL_EXTERNAL_PORT=' | cut -d '=' -f2- | tr -d '\r' || true)
  fi
  if [ -z "$MSSQL_ENV_PORT" ]; then
    MSSQL_ENV_PORT=$(grep -v '^#' "$ROOT_DIR/mssql/.env" | grep 'MSSQL_PORT=' | cut -d '=' -f2- | tr -d '\r' || true)
  fi
  MSSQL_ENV_DB=$(grep -v '^#' "$ROOT_DIR/mssql/.env" | grep 'MSSQL_DB=' | cut -d '=' -f2- | tr -d '\r' || true)
  MSSQL_ENV_USER=$(grep -v '^#' "$ROOT_DIR/mssql/.env" | grep 'MSSQL_USER=' | cut -d '=' -f2- | tr -d '\r' || true)
  MSSQL_ENV_PASS=$(grep -v '^#' "$ROOT_DIR/mssql/.env" | grep 'MSSQL_PASSWORD=' | cut -d '=' -f2- | tr -d '\r' || true)
  MSSQL_ENV_TABLE=$(grep -v '^#' "$ROOT_DIR/mssql/.env" | grep 'MSSQL_TABLE_REDIS_SERVER=' | cut -d '=' -f2- | tr -d '\r' || true)
  MSSQL_ENV_DB_ENCRYPT=$(grep -v '^#' "$ROOT_DIR/mssql/.env" | grep '^DB_ENCRYPT=' | cut -d '=' -f2- | tr -d '\r' || true)
  MSSQL_ENV_TRUST_CERT=$(grep -v '^#' "$ROOT_DIR/mssql/.env" | grep '^DB_TRUST_SERVER_CERTIFICATE=' | cut -d '=' -f2- | tr -d '\r' || true)
  MSSQL_ENV_TLS_ENABLED=$(grep -v '^#' "$ROOT_DIR/mssql/.env" | grep '^MSSQL_TLS_ENABLED=' | cut -d '=' -f2- | tr -d '\r' || true)
fi

# 2. Redis 환경 변수 로드 (redis/.env)
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  source "$SCRIPT_DIR/.env"
  set +a
elif [ -f .env ]; then
  set -a
  source .env
  set +a
fi

# 3. 접속 및 등록 변수 확정
REDIS_IP="${REDIS_EXTERNAL_IP:-}"
REDIS_EXT_PORT="${REDIS_EXTERNAL_PORT:-6379}"
: "${REDIS_IP:?REDIS_EXTERNAL_IP must be the private address of the Redis HA primary}"
if [[ ! "$REDIS_IP" =~ ^[0-9A-Fa-f:.]+$ ]]; then
  echo "REDIS_EXTERNAL_IP must be a literal IPv4 or IPv6 address." >&2
  exit 2
fi
python3 - "$REDIS_IP" <<'PY'
import ipaddress
import sys

address = ipaddress.ip_address(sys.argv[1])
if not address.is_private or address.is_loopback or address.is_link_local or address.is_multicast or address.is_unspecified:
    raise SystemExit("REDIS_EXTERNAL_IP must be a private unicast address, not loopback or wildcard.")
PY
if [[ ! "$REDIS_EXT_PORT" =~ ^[0-9]+$ ]] || (( REDIS_EXT_PORT < 1 || REDIS_EXT_PORT > 65535 )); then
  echo "REDIS_EXTERNAL_PORT must be a port from 1 through 65535." >&2
  exit 2
fi

MSSQL_RAW_HOST="${MSSQL_TEST_HOST:-${DB_HOST:-${MSSQL_HOST:-${MSSQL_ENV_HOST:-127.0.0.1}}}}"
if [ "$MSSQL_RAW_HOST" = "0.0.0.0" ]; then
  MSSQL_HOST="127.0.0.1"
else
  MSSQL_HOST="$MSSQL_RAW_HOST"
fi
MSSQL_PORT="${MSSQL_TEST_PORT:-${DB_PORT:-${MSSQL_PORT:-${MSSQL_ENV_PORT:-1433}}}}"
MSSQL_DB="${MSSQL_DB:-${MSSQL_ENV_DB:-agora_db}}"
MSSQL_USER="${MSSQL_USER:-${MSSQL_ENV_USER:-agora_user}}"
MSSQL_PASS="${MSSQL_PASSWORD:-${MSSQL_ENV_PASS:-}}"
: "${MSSQL_PASS:?MSSQL_PASSWORD must be configured in mssql/.env or the environment}"
MSSQL_TABLE="${MSSQL_TABLE_REDIS_SERVER:-${MSSQL_ENV_TABLE:-redis_server}}"
DB_ENCRYPT="${MSSQL_ENV_DB_ENCRYPT:-true}"
DB_TRUST_SERVER_CERTIFICATE="${MSSQL_ENV_TRUST_CERT:-false}"
MSSQL_TLS_ENABLED="${MSSQL_ENV_TLS_ENABLED:-true}"
if [ -n "$DB_ENCRYPT_OVERRIDE" ]; then DB_ENCRYPT="$DB_ENCRYPT_OVERRIDE"; fi
if [ -n "$DB_TRUST_CERT_OVERRIDE" ]; then DB_TRUST_SERVER_CERTIFICATE="$DB_TRUST_CERT_OVERRIDE"; fi
if [ -n "$MSSQL_TLS_OVERRIDE" ]; then MSSQL_TLS_ENABLED="$MSSQL_TLS_OVERRIDE"; fi
SQLCMD_TLS_ARGS=()
if [ "$DB_ENCRYPT" != "false" ]; then SQLCMD_TLS_ARGS+=(-N); fi
if [ "$DB_TRUST_SERVER_CERTIFICATE" = "true" ] || [ "$MSSQL_TLS_ENABLED" != "true" ] || [ "$DB_ENCRYPT" = "false" ]; then
  echo "[ERROR] SQL connections require TLS and certificate verification." >&2
  exit 1
fi

echo "=================================================================="
echo "  Agora Redis -> MS SQL External Endpoint Registration"
echo "=================================================================="
echo "  - 등록 대상 Redis HA primary 사설 IP: $REDIS_IP"
echo "  - Redis 서비스 포트:                 $REDIS_EXT_PORT"
echo "  - 대상 MS SQL 서버:          $MSSQL_HOST:$MSSQL_PORT ($MSSQL_DB)"
echo "  - 대상 테이블:               $MSSQL_TABLE"
echo "=================================================================="

# 4. sqlcmd 실행 래퍼 함수 (로컬 sqlcmd 우선, 없으면 docker exec fallback)
run_mssql_cmd() {
  local sql_query="$1"
  if command -v sqlcmd &> /dev/null; then
    export SSL_CERT_FILE="${SSL_CERT_FILE:-${MSSQL_ENV_CA_FILE:-$ROOT_DIR/mssql/tls/ca.crt}}"
    SQLCMDPASSWORD="$MSSQL_PASS" sqlcmd -S "$MSSQL_HOST,$MSSQL_PORT" -U "$MSSQL_USER" ${SQLCMD_TLS_ARGS[@]+"${SQLCMD_TLS_ARGS[@]}"} -b -I -d "$MSSQL_DB" -Q "$sql_query" -W
  elif [[ "$MSSQL_HOST" == "127.0.0.1" || "$MSSQL_HOST" == "localhost" || "$MSSQL_HOST" == "::1" ]] \
      && docker inspect --format '{{.State.Running}}' agora-mssql 2>/dev/null | grep -q '^true$'; then
    docker exec agora-mssql /bin/bash -lc \
      'export SQLCMDPASSWORD="$MSSQL_PASSWORD"; exec /opt/mssql-tools18/bin/sqlcmd "$@"' \
      sqlcmd -S localhost -U "$MSSQL_USER" ${SQLCMD_TLS_ARGS[@]+"${SQLCMD_TLS_ARGS[@]}"} -b -I -d "$MSSQL_DB" -Q "$sql_query" -W
  else
    echo "[ERROR] sqlcmd is required for the configured SQL Server endpoint $MSSQL_HOST:$MSSQL_PORT. Docker fallback is only available for a running local agora-mssql container." >&2
    return 127
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

# 6. Redis HA는 SQL에 하나의 논리 서비스만 활성화합니다.
#    기존 행은 FK 참조를 보존한 채 비활성화하고 대상 HA 주소만 upsert합니다.
REGISTER_SQL=$(cat <<EOF
SET NOCOUNT ON;
SET XACT_ABORT ON;
BEGIN TRANSACTION;
UPDATE [$MSSQL_TABLE] SET is_activated = 0 WHERE is_activated <> 0;
IF EXISTS (SELECT 1 FROM [$MSSQL_TABLE] WHERE redis_ip = '$REDIS_IP' AND redis_port = '$REDIS_EXT_PORT')
BEGIN
    UPDATE [$MSSQL_TABLE]
    SET is_activated = 1
    WHERE redis_ip = '$REDIS_IP' AND redis_port = '$REDIS_EXT_PORT';
    SELECT 'ALREADY_EXISTS' AS [result_status];
END
ELSE
BEGIN
    INSERT INTO [$MSSQL_TABLE] (redis_ip, redis_port, is_activated)
    VALUES ('$REDIS_IP', '$REDIS_EXT_PORT', 1);
    SELECT 'SUCCESS_INSERTED' AS [result_status];
END;
COMMIT TRANSACTION;
EOF
)

RESULT_OUT=$(run_mssql_cmd "$REGISTER_SQL" 2>&1)

if echo "$RESULT_OUT" | grep -q "SUCCESS_INSERTED"; then
  echo -e "\n[OK] 신규 Redis 서버가 MS SQL [$MSSQL_TABLE] 테이블에 성공적으로 등록되었습니다!"
  echo "     (HA primary private address: $REDIS_IP, port: $REDIS_EXT_PORT)"
elif echo "$RESULT_OUT" | grep -q "ALREADY_EXISTS"; then
  echo -e "\n[INFO] Redis HA 논리 서비스($REDIS_IP:$REDIS_EXT_PORT)가 이미 등록되어 활성화되었습니다."
else
  echo -e "\n[ERROR] Redis 서버 등록 중 예기치 않은 응답이 발생했습니다:"
  echo "$RESULT_OUT"
  exit 1
fi

# 7. 현재 등록된 Redis 서버 목록 출력
echo -e "\n=== 현재 MS SQL [$MSSQL_TABLE] 에 등록된 Redis 서버 목록 ==="
LIST_SQL="SELECT redis_id, redis_ip, redis_port, is_activated, created_at FROM [$MSSQL_TABLE];"
run_mssql_cmd "$LIST_SQL"

echo -e "\n[SUCCESS] Redis 외부 접속 정보의 MS SQL 등록 작업이 완료되었습니다.\n"
