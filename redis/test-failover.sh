#!/usr/bin/env bash
# Exercise automatic Sentinel failover in the local six-container lab.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
MASTER_NAME="agora-master"
NODES=(agora-redis-primary agora-redis-replica-1 agora-redis-replica-2)
SENTINELS=(agora-redis-sentinel-1 agora-redis-sentinel-2 agora-redis-sentinel-3)

read_env() {
  sed -n "s/^$1=//p" "$ENV_FILE" 2>/dev/null | tail -n 1 | tr -d '\r'
}

REDIS_ADMIN_PASSWORD="${REDIS_PASSWORD:-$(read_env REDIS_PASSWORD)}"
REDIS_APP_USER="${REDIS_USER:-$(read_env REDIS_USER)}"
REDIS_APP_PASSWORD="${REDIS_USER_PASSWORD:-$(read_env REDIS_USER_PASSWORD)}"
REDIS_SENTINEL_USER="${REDIS_SENTINEL_USER:-$(read_env REDIS_SENTINEL_USER)}"
REDIS_SENTINEL_PASSWORD="${REDIS_SENTINEL_PASSWORD:-$(read_env REDIS_SENTINEL_PASSWORD)}"
REDIS_INDEX="${REDIS_INDEX_NAME:-$(read_env REDIS_INDEX_NAME)}"
REDIS_INDEX="${REDIS_INDEX:-idx:canvas}"
REDIS_APP_USER="${REDIS_APP_USER:-agora_user}"
: "${REDIS_ADMIN_PASSWORD:?Set REDIS_PASSWORD in redis/.env}"
: "${REDIS_APP_PASSWORD:?Set REDIS_USER_PASSWORD in redis/.env}"
if [ -n "$REDIS_SENTINEL_USER" ] && [ -z "$REDIS_SENTINEL_PASSWORD" ] \
  || [ -z "$REDIS_SENTINEL_USER" ] && [ -n "$REDIS_SENTINEL_PASSWORD" ]; then
  echo "REDIS_SENTINEL_USER and REDIS_SENTINEL_PASSWORD must be set together" >&2
  exit 1
fi

PROBE_TAG="haft$(date +%s)$$"
PROBE_KEY="canvas:$PROBE_TAG"
PROBE_ID="$(date +%s)"
PROBE_CREATED=0
ORIGINAL_PRIMARY=""

die() {
  echo "[FAIL] $*" >&2
  exit 1
}

is_running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" = "true" ]
}

node_role() {
  local info
  info="$(docker exec -e REDISCLI_AUTH="$REDIS_ADMIN_PASSWORD" "$1" \
    redis-cli --raw INFO replication 2>/dev/null)" || return 1
  printf '%s\n' "$info" | sed -n 's/^role://p' | tr -d '\r' | head -n 1
}

find_primary() {
  local node role found="" count=0
  for node in "${NODES[@]}"; do
    is_running "$node" || continue
    role="$(node_role "$node" 2>/dev/null || true)"
    if [ "$role" = "master" ]; then
      found="$node"
      count=$((count + 1))
    fi
  done
  [ "$count" -eq 1 ] || return 1
  printf '%s\n' "$found"
}

app_cli() {
  local node="$1"
  shift
  docker exec -e REDISCLI_AUTH="$REDIS_APP_PASSWORD" "$node" \
    redis-cli --user "$REDIS_APP_USER" --no-auth-warning --raw "$@"
}

verify_probe() {
  local node="$1" json search_result
  json="$(app_cli "$node" JSON.GET "$PROBE_KEY" '$' 2>/dev/null)" || return 1
  [[ "$json" == *"$PROBE_TAG"* ]] || return 1
  search_result="$(app_cli "$node" FT.SEARCH "$REDIS_INDEX" \
    "@init_group:{$PROBE_TAG}" LIMIT 0 1 2>/dev/null)" || return 1
  [[ "$search_result" == *"$PROBE_KEY"* ]]
}

sentinel_matches_primary() {
  local primary="$1" sentinel report host port ip aliases
  local sentinel_auth_args=()
  if [ -n "$REDIS_SENTINEL_PASSWORD" ]; then
    sentinel_auth_args=(--user "$REDIS_SENTINEL_USER")
  fi
  for sentinel in "${SENTINELS[@]}"; do
    report="$(docker exec -e REDISCLI_AUTH="$REDIS_SENTINEL_PASSWORD" "$sentinel" \
      redis-cli --raw -p 26379 "${sentinel_auth_args[@]}" \
      SENTINEL get-master-addr-by-name "$MASTER_NAME" 2>/dev/null)" || return 1
    host="$(printf '%s\n' "$report" | sed -n '1p' | tr -d '\r')"
    port="$(printf '%s\n' "$report" | sed -n '2p' | tr -d '\r')"
    [ "$port" = "6379" ] || return 1
    ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$primary")"
    [ "$host" = "$ip" ] && continue
    aliases="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{range .Aliases}}{{println .}}{{end}}{{end}}' "$primary")"
    printf '%s\n' "$aliases" | grep -Fxq -- "$host" || return 1
  done
}

wait_for_failover() {
  local old_primary="$1" deadline=$((SECONDS + 120)) primary=""
  while (( SECONDS < deadline )); do
    primary="$(find_primary 2>/dev/null || true)"
    if [ -n "$primary" ] && [ "$primary" != "$old_primary" ] \
      && sentinel_matches_primary "$primary"; then
      printf '%s\n' "$primary"
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_restored_cluster() {
  local deadline=$((SECONDS + 120)) primary="" node role masters=0 replicas=0
  while (( SECONDS < deadline )); do
    masters=0
    replicas=0
    primary=""
    for node in "${NODES[@]}"; do
      is_running "$node" || continue
      role="$(node_role "$node" 2>/dev/null || true)"
      if [ "$role" = "master" ]; then
        masters=$((masters + 1))
        primary="$node"
      elif [ "$role" = "slave" ] || [ "$role" = "replica" ]; then
        replicas=$((replicas + 1))
      fi
    done
    if [ "$masters" -eq 1 ] && [ "$replicas" -eq 2 ] \
      && sentinel_matches_primary "$primary"; then
      printf '%s\n' "$primary"
      return 0
    fi
    sleep 1
  done
  return 1
}

cleanup() {
  local status=$? node=""
  trap - EXIT
  if [ -n "$ORIGINAL_PRIMARY" ] && ! is_running "$ORIGINAL_PRIMARY"; then
    echo "[INFO] Restarting the original primary container $ORIGINAL_PRIMARY"
    docker start "$ORIGINAL_PRIMARY" >/dev/null 2>&1 || true
  fi
  if [ "$PROBE_CREATED" -eq 1 ]; then
    for _ in {1..30}; do
      node="$(find_primary 2>/dev/null || true)"
      [ -n "$node" ] && break
      sleep 1
    done
    if [ -n "$node" ]; then
      app_cli "$node" DEL "$PROBE_KEY" >/dev/null 2>&1 || true
    fi
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

command -v docker >/dev/null 2>&1 || die "docker is required"
[ -f "$ENV_FILE" ] || die "Environment file not found: $ENV_FILE"

for container in "${NODES[@]}" "${SENTINELS[@]}"; do
  is_running "$container" || die "Local Sentinel lab container is not running: $container"
done

ORIGINAL_PRIMARY="$(find_primary)" || die "Expected exactly one running Redis primary"
echo "[INFO] Current primary: $ORIGINAL_PRIMARY"

payload="$(printf '{\"canvas-name\":\"%s\",\"canvas-id\":%s,\"admin-user-id\":1,\"description\":\"temporary Sentinel failover probe\",\"canvas-password-hash\":\"probe\",\"people\":[],\"init-group\":\"%s\"}' \
  "$PROBE_TAG" "$PROBE_ID" "$PROBE_TAG")"
app_cli "$ORIGINAL_PRIMARY" JSON.SET "$PROBE_KEY" '$' "$payload" >/dev/null \
  || die "Could not write the temporary probe document using the application ACL"
PROBE_CREATED=1

replicas_ready=0
for _ in {1..60}; do
  replicas_ready=1
  for node in "${NODES[@]}"; do
    [ "$node" = "$ORIGINAL_PRIMARY" ] && continue
    if ! verify_probe "$node"; then
      replicas_ready=0
      break
    fi
  done
  [ "$replicas_ready" -eq 1 ] && break
  sleep 1
done
[ "$replicas_ready" -eq 1 ] || die "Probe did not replicate to both replicas"
verify_probe "$ORIGINAL_PRIMARY" || die "RediSearch did not find the probe on the primary"

echo "[INFO] Stopping the current primary to trigger automatic Sentinel failover"
docker stop --time 5 "$ORIGINAL_PRIMARY" >/dev/null
NEW_PRIMARY="$(wait_for_failover "$ORIGINAL_PRIMARY")" \
  || die "Sentinel did not promote a replica within 120 seconds"
echo "[INFO] Promoted primary: $NEW_PRIMARY"
verify_probe "$NEW_PRIMARY" || die "Probe JSON or RediSearch query failed after promotion"

echo "[INFO] Restarting the old primary and waiting for it to rejoin as a replica"
docker start "$ORIGINAL_PRIMARY" >/dev/null
RESTORED_PRIMARY="$(wait_for_restored_cluster)" \
  || die "The three-node Redis topology did not recover within 120 seconds"
for node in "${NODES[@]}"; do
  verify_probe "$node" || die "Probe JSON or RediSearch query failed on $node after recovery"
done

app_cli "$RESTORED_PRIMARY" DEL "$PROBE_KEY" >/dev/null
PROBE_CREATED=0
echo "[PASS] Automatic failover, Sentinel discovery, ACL, RedisJSON, RediSearch, and replica recovery passed."
echo "[INFO] Active primary after the test: $RESTORED_PRIMARY"
