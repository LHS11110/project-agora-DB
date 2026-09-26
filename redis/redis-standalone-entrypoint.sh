#!/bin/sh
set -eu
umask 077

: "${REDIS_PASSWORD:?REDIS_PASSWORD must be set in redis/.env}"
: "${REDIS_USER_PASSWORD:?REDIS_USER_PASSWORD must be set in redis/.env}"
REDIS_USER="${REDIS_USER:-agora_user}"
REDIS_KEY_PREFIX="${REDIS_KEY_PREFIX:-canvas:}"
REDIS_INDEX_NAME="${REDIS_INDEX_NAME:-idx:canvas}"
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

exec /usr/local/bin/docker-entrypoint.sh redis-server \
  --dir /data \
  --port "${REDIS_NODE_PORT:-6379}" \
  --appendonly yes \
  --protected-mode yes \
  --aclfile "$ACL_FILE"
