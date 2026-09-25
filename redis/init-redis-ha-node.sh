#!/bin/bash
# Initialize the ACL on this host's Redis node. Create the JSON search index
# and register the endpoint only when this node is the current primary.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
read_env() {
  sed -n "s/^$1=//p" "$SCRIPT_DIR/.env" 2>/dev/null | tail -n 1 | tr -d '\r'
}

REDIS_PASSWORD="${REDIS_PASSWORD:-$(read_env REDIS_PASSWORD)}"
REDIS_USER_PASSWORD="${REDIS_USER_PASSWORD:-$(read_env REDIS_USER_PASSWORD)}"
REDIS_USER="${REDIS_USER:-$(read_env REDIS_USER)}"
REDIS_KEY_PREFIX="${REDIS_KEY_PREFIX:-$(read_env REDIS_KEY_PREFIX)}"
REDIS_INDEX_NAME="${REDIS_INDEX_NAME:-$(read_env REDIS_INDEX_NAME)}"
: "${REDIS_PASSWORD:?REDIS_PASSWORD must be set in redis/.env}"
: "${REDIS_USER_PASSWORD:?REDIS_USER_PASSWORD must be set in redis/.env}"
REDIS_USER="${REDIS_USER:-agora_user}"
REDIS_KEY_PREFIX="${REDIS_KEY_PREFIX:-canvas:}"
REDIS_INDEX_NAME="${REDIS_INDEX_NAME:-idx:canvas}"

node_config() {
  docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' agora-redis-node \
    | sed -n "s/^$1=//p" | tail -n 1
}
REDIS_NODE_BIND_IP="${REDIS_NODE_BIND_IP:-$(node_config REDIS_NODE_BIND_IP)}"
REDIS_NODE_PORT="${REDIS_NODE_PORT:-$(node_config REDIS_NODE_PORT)}"
REDIS_NODE_PORT="${REDIS_NODE_PORT:-6379}"
: "${REDIS_NODE_BIND_IP:?REDIS_NODE_BIND_IP must be set on the Redis node}"

ready=false
for attempt in {1..90}; do
  if docker exec -e REDISCLI_AUTH="$REDIS_PASSWORD" agora-redis-node \
    redis-cli -h "$REDIS_NODE_BIND_IP" -p "$REDIS_NODE_PORT" ping 2>/dev/null | grep -q PONG; then
    ready=true
    break
  fi
  sleep 1
done
if [ "$ready" != true ]; then
  echo "Redis node did not become ready: agora-redis-node" >&2
  exit 1
fi

docker exec -e REDISCLI_AUTH="$REDIS_PASSWORD" agora-redis-node redis-cli \
  -h "$REDIS_NODE_BIND_IP" -p "$REDIS_NODE_PORT" \
  ACL SETUSER "$REDIS_USER" reset on ">$REDIS_USER_PASSWORD" \
  "~${REDIS_KEY_PREFIX}*" "~${REDIS_INDEX_NAME}*" resetchannels -@all \
  +auth +ping +role +json.get +json.set +json.arrlen +json.arrappend +json.del \
  +get +del +exists +keys +eval +ft.search +ft.info
docker exec -e REDISCLI_AUTH="$REDIS_PASSWORD" agora-redis-node \
  redis-cli -h "$REDIS_NODE_BIND_IP" -p "$REDIS_NODE_PORT" ACL SAVE

ROLE=$(docker exec -e REDISCLI_AUTH="$REDIS_PASSWORD" agora-redis-node \
  redis-cli -h "$REDIS_NODE_BIND_IP" -p "$REDIS_NODE_PORT" --raw INFO replication \
  | sed -n 's/^role://p' | tr -d '\r')
if [ "$ROLE" = "master" ]; then
  REDIS_CONNECT_HOST="$REDIS_NODE_BIND_IP" REDIS_CONNECT_PORT="$REDIS_NODE_PORT" \
    bash "$SCRIPT_DIR/init-redis.sh"
else
  echo "ACL initialized on replica; the primary creates the search index and registers the endpoint."
fi
