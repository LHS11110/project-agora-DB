#!/bin/sh
set -eu
umask 077

: "${REDIS_PASSWORD:?REDIS_PASSWORD must be set in redis/.env}"
: "${REDIS_USER_PASSWORD:?REDIS_USER_PASSWORD must be set in redis/.env}"
REDIS_USER="${REDIS_USER:-agora_user}"
REDIS_KEY_PREFIX="${REDIS_KEY_PREFIX:-canvas:}"
REDIS_INDEX_NAME="${REDIS_INDEX_NAME:-idx:canvas}"
REDIS_NODE_PORT="${REDIS_NODE_PORT:-6379}"
REDIS_TLS_ENABLED="${REDIS_TLS_ENABLED:-false}"
REDIS_TLS_CERTIFICATE="${REDIS_TLS_CERTIFICATE:-/run/secrets/redis-tls/server.crt}"
REDIS_TLS_KEY="${REDIS_TLS_KEY:-/run/secrets/redis-tls/server.key}"
REDIS_TLS_CA_CERT="${REDIS_TLS_CA_CERT:-/run/secrets/redis-tls/ca.crt}"
case "$REDIS_TLS_ENABLED" in
  true|false) ;;
  *) echo "REDIS_TLS_ENABLED must be true or false." >&2; exit 1 ;;
esac
if [ "$REDIS_TLS_ENABLED" = true ]; then
  for tls_file in "$REDIS_TLS_CERTIFICATE" "$REDIS_TLS_KEY" "$REDIS_TLS_CA_CERT"; do
    if [ ! -r "$tls_file" ]; then
      echo "Redis TLS file is not readable: $tls_file" >&2
      exit 1
    fi
  done
fi
chown redis:redis /data
if [ -f /data/dump.rdb ]; then chown redis:redis /data/dump.rdb; fi

case "$REDIS_USER" in
  *[!A-Za-z0-9_.-]*) echo "REDIS_USER contains unsupported ACL username characters." >&2; exit 1 ;;
esac
case "$REDIS_KEY_PREFIX$REDIS_INDEX_NAME" in
  *[[:space:]]*) echo "Redis ACL key patterns may not contain whitespace." >&2; exit 1 ;;
esac

ADMIN_HASH=$(printf '%s' "$REDIS_PASSWORD" | sha256sum | awk '{print $1}')
APP_HASH=$(printf '%s' "$REDIS_USER_PASSWORD" | sha256sum | awk '{print $1}')
ACL_FILE=/data/users.acl
ACL_TEMP="${ACL_FILE}.tmp"

{
  printf 'user default on #%s ~* &* +@all\n' "$ADMIN_HASH"
  printf 'user %s on #%s ~%s* ~%s* resetchannels -@all +auth +ping +role +json.get +json.set +json.arrlen +json.arrappend +json.del +get +del +exists +keys +eval +ft.search +ft.info\n' \
    "$REDIS_USER" "$APP_HASH" "$REDIS_KEY_PREFIX" "$REDIS_INDEX_NAME"
} > "$ACL_TEMP"
chown redis:redis "$ACL_TEMP"
chmod 600 "$ACL_TEMP"
mv "$ACL_TEMP" "$ACL_FILE"

if [ "$REDIS_TLS_ENABLED" = true ]; then
  TLS_RUNTIME_DIR=/data/tls
  mkdir -p "$TLS_RUNTIME_DIR"
  cp "$REDIS_TLS_CERTIFICATE" "$TLS_RUNTIME_DIR/server.crt"
  cp "$REDIS_TLS_KEY" "$TLS_RUNTIME_DIR/server.key"
  cp "$REDIS_TLS_CA_CERT" "$TLS_RUNTIME_DIR/ca.crt"
  chown -R redis:redis "$TLS_RUNTIME_DIR"
  chmod 0700 "$TLS_RUNTIME_DIR/server.key"
  chmod 0644 "$TLS_RUNTIME_DIR/server.crt" "$TLS_RUNTIME_DIR/ca.crt"
  exec /usr/local/bin/docker-entrypoint.sh redis-server \
    --dir /data \
    --port 0 \
    --tls-port "$REDIS_NODE_PORT" \
    --tls-cert-file "$TLS_RUNTIME_DIR/server.crt" \
    --tls-key-file "$TLS_RUNTIME_DIR/server.key" \
    --tls-ca-cert-file "$TLS_RUNTIME_DIR/ca.crt" \
    --tls-auth-clients no \
    --tls-protocols "TLSv1.2 TLSv1.3" \
    --appendonly yes \
    --protected-mode yes \
    --aclfile "$ACL_FILE"
fi

exec /usr/local/bin/docker-entrypoint.sh redis-server \
  --dir /data \
  --port "$REDIS_NODE_PORT" \
  --appendonly yes \
  --protected-mode yes \
  --aclfile "$ACL_FILE"
