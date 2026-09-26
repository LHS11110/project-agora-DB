#!/bin/sh
set -eu

MODE="${1:-node}"
TLS_ENABLED="${REDIS_TLS_ENABLED:-false}"
TLS_CA_CERT="${REDIS_TLS_CA_CERT:-/run/secrets/redis-tls/ca.crt}"

case "$MODE" in
  node)
    REDISCLI_AUTH="${REDIS_PASSWORD:?REDIS_PASSWORD is required}"
    REDIS_USER=""
    REDIS_PORT="${REDIS_NODE_PORT:-6379}"
    REDIS_HOST="${REDIS_NODE_BIND_IP:-127.0.0.1}"
    ;;
  sentinel)
    REDISCLI_AUTH="${REDIS_SENTINEL_PASSWORD:?REDIS_SENTINEL_PASSWORD is required}"
    REDIS_USER="${REDIS_SENTINEL_USER:?REDIS_SENTINEL_USER is required}"
    REDIS_PORT="${REDIS_SENTINEL_PORT:-26379}"
    REDIS_HOST=127.0.0.1
    ;;
  *) echo "Unsupported Redis healthcheck mode: $MODE" >&2; exit 2 ;;
esac

if [ "$TLS_ENABLED" = true ]; then
  if [ ! -r "$TLS_CA_CERT" ]; then
    echo "Redis TLS CA is not readable: $TLS_CA_CERT" >&2
    exit 1
  fi
  if [ -n "$REDIS_USER" ]; then
    REDISCLI_AUTH="$REDISCLI_AUTH" redis-cli --tls --cacert "$TLS_CA_CERT" \
      -h "$REDIS_HOST" -p "$REDIS_PORT" --user "$REDIS_USER" --no-auth-warning ping | grep -q PONG
  else
    REDISCLI_AUTH="$REDISCLI_AUTH" redis-cli --tls --cacert "$TLS_CA_CERT" \
      -h "$REDIS_HOST" -p "$REDIS_PORT" ping | grep -q PONG
  fi
else
  if [ -n "$REDIS_USER" ]; then
    REDISCLI_AUTH="$REDISCLI_AUTH" redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" \
      --user "$REDIS_USER" --no-auth-warning ping | grep -q PONG
  else
    REDISCLI_AUTH="$REDISCLI_AUTH" redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" ping | grep -q PONG
  fi
fi
