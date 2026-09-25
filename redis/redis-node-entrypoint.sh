#!/bin/sh
set -eu

: "${REDIS_PASSWORD:?REDIS_PASSWORD must be set in redis/.env}"
: "${REDIS_NODE_ANNOUNCE_IP:?REDIS_NODE_ANNOUNCE_IP is required}"
REDIS_NODE_BIND_IP="${REDIS_NODE_BIND_IP:-$REDIS_NODE_ANNOUNCE_IP}"

set -- redis-server \
  --port "${REDIS_NODE_PORT:-6379}" \
  --bind "$REDIS_NODE_BIND_IP" \
  --requirepass "$REDIS_PASSWORD" \
  --masterauth "$REDIS_PASSWORD" \
  --appendonly yes \
  --protected-mode yes \
  --aclfile /data/users.acl \
  --replica-announce-ip "$REDIS_NODE_ANNOUNCE_IP" \
  --replica-announce-port "${REDIS_NODE_PORT:-6379}"

if [ -n "${REDIS_NODE_PRIMARY_HOST:-}" ]; then
  set -- "$@" --replicaof "$REDIS_NODE_PRIMARY_HOST" "${REDIS_NODE_PRIMARY_PORT:-6379}"
fi

exec "$@"
