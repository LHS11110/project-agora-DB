#!/bin/bash
# ==============================================================================
# Redis Sentinel HA (RedisJSON + RediSearch) initialization.
# Sentinel is the only supported connection path; SQL keeps one logical HA row.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi

: "${REDIS_SENTINELS:?REDIS_SENTINELS must list the Redis HA Sentinel endpoints}"
: "${REDIS_SENTINEL_USER:?REDIS_SENTINEL_USER must be set in redis/.env}"
: "${REDIS_SENTINEL_PASSWORD:?REDIS_SENTINEL_PASSWORD must be set in redis/.env}"
: "${REDIS_EXTERNAL_IP:?REDIS_EXTERNAL_IP must be the private HA primary address registered in SQL}"
REDIS_EXTERNAL_PORT="${REDIS_EXTERNAL_PORT:-6379}"
: "${REDIS_PASSWORD:?REDIS_PASSWORD must be set in redis/.env}"
REDIS_ADMIN_PASS="$REDIS_PASSWORD"
REDIS_USER="${REDIS_USER:-agora_user}"
: "${REDIS_USER_PASSWORD:?REDIS_USER_PASSWORD must be set in redis/.env}"
REDIS_USER_PASS="$REDIS_USER_PASSWORD"
REDIS_INDEX_NAME="${REDIS_INDEX_NAME:-idx:canvas}"
REDIS_KEY_PREFIX="${REDIS_KEY_PREFIX:-canvas:}"

run_on_local_primary() {
  local mode="$1"; shift
  local container role bind_ip port
  for container in agora-redis-primary agora-redis-replica-1 agora-redis-replica-2 agora-redis-node; do
    [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)" = true ] || continue
    local node_args=()
    if [ "$container" = agora-redis-node ]; then
      bind_ip="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$container" \
        | sed -n 's/^REDIS_NODE_BIND_IP=//p' | tail -n 1 | tr -d '\r')"
      port="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$container" \
        | sed -n 's/^REDIS_NODE_PORT=//p' | tail -n 1 | tr -d '\r')"
      node_args=(-h "${bind_ip:-127.0.0.1}" -p "${port:-6379}")
    fi
    # Bash 3.2 treats empty arrays as unset under nounset; expand only when set.
    role="$("$SCRIPT_DIR/redis-container-cli.sh" "$container" admin ${node_args[@]+"${node_args[@]}"} --raw INFO replication 2>/dev/null \
      | sed -n 's/^role://p' | tr -d '\r')"
    if [ "$role" = master ]; then
      "$SCRIPT_DIR/redis-container-cli.sh" "$container" "$mode" ${node_args[@]+"${node_args[@]}"} "$@"
      return $?
    fi
  done
  echo "Could not find a local Sentinel-managed primary." >&2
  return 1
}

use_local_docker() {
  command -v docker >/dev/null 2>&1 || return 1
  local container
  for container in agora-redis-primary agora-redis-replica-1 agora-redis-replica-2 agora-redis-node; do
    if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || true)" = true ]; then
      return 0
    fi
  done
  return 1
}

run_admin_cli() {
  if use_local_docker; then
    "$SCRIPT_DIR/redis-ha-cli.sh" "$@"
  elif command -v redis-cli >/dev/null 2>&1; then
    "$SCRIPT_DIR/redis-host-cli.sh" admin "$@"
  else
    "$SCRIPT_DIR/redis-ha-cli.sh" "$@"
  fi
}
run_user_cli() {
  if use_local_docker; then
    run_on_local_primary app "$@"
  elif command -v redis-cli >/dev/null 2>&1; then
    "$SCRIPT_DIR/redis-host-cli.sh" app "$@"
  else
    run_on_local_primary app "$@"
  fi
}
provision_app_acl() {
  if use_local_docker; then
    run_on_local_primary provision-app
  elif command -v redis-cli >/dev/null 2>&1; then
    printf '>%s' "$REDIS_USER_PASS" | "$SCRIPT_DIR/redis-host-cli.sh" admin -x \
      ACL SETUSER "$REDIS_USER" reset on \
      "~${REDIS_KEY_PREFIX}*" "~${REDIS_INDEX_NAME}*" resetchannels -@all \
      +auth +ping +role +json.get +json.set +json.arrlen +json.arrappend +json.del \
      +get +del +exists +keys +eval +ft.search +ft.info
  else
    run_on_local_primary provision-app
  fi
}

echo "=== 1. Redis ACL 사용자 ($REDIS_USER) 생성 및 권한 부여 ==="
# Keep commands used by the BE and failover/inspection checks, limited to the
# application's key namespace and RediSearch index.
provision_app_acl
run_admin_cli ACL SAVE
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

echo -e "\n=== 4. MS SQL에 Redis HA 논리 서비스($REDIS_EXTERNAL_IP:$REDIS_EXTERNAL_PORT) 등록 ==="
if [ -f "$SCRIPT_DIR/register-to-mssql.sh" ]; then
  bash "$SCRIPT_DIR/register-to-mssql.sh"
else
  echo "[WARN] $SCRIPT_DIR/register-to-mssql.sh 스크립트를 찾을 수 없어 MS SQL 등록을 건너뜁니다."
fi

echo -e "\n[SUCCESS] Redis HA ACL/인덱스 구성 및 단일 논리 서비스 SQL 등록이 완료되었습니다."
