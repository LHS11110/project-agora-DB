#!/usr/bin/env bash
set -euo pipefail

CONTAINER="${1:?Usage: redis-container-cli.sh CONTAINER admin|app|sentinel|provision-app [redis-cli args...]}"
MODE="${2:?A Redis authentication mode is required}"
shift 2

exec docker exec "$CONTAINER" /bin/sh -c '
  mode="$1"
  shift
  case "$mode" in
    admin)
      : "${REDIS_PASSWORD:?REDIS_PASSWORD is not set in the container environment}"
      REDISCLI_AUTH="$REDIS_PASSWORD" exec redis-cli "$@"
      ;;
    app)
      : "${REDIS_USER_PASSWORD:?REDIS_USER_PASSWORD is not set in the container environment}"
      REDISCLI_AUTH="$REDIS_USER_PASSWORD" exec redis-cli --user "${REDIS_USER:-agora_user}" --no-auth-warning "$@"
      ;;
    sentinel)
      : "${REDIS_SENTINEL_PASSWORD:?REDIS_SENTINEL_PASSWORD is not set in the container environment}"
      : "${REDIS_SENTINEL_USER:?REDIS_SENTINEL_USER is not set in the container environment}"
      REDISCLI_AUTH="$REDIS_SENTINEL_PASSWORD" exec redis-cli -p 26379 --user "$REDIS_SENTINEL_USER" --no-auth-warning "$@"
      ;;
    provision-app)
      : "${REDIS_USER_PASSWORD:?REDIS_USER_PASSWORD is not set in the container environment}"
      printf ">%s" "$REDIS_USER_PASSWORD" | REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli -x \
        ACL SETUSER "${REDIS_USER:-agora_user}" reset on \
        "~${REDIS_KEY_PREFIX:-canvas:}*" "~${REDIS_INDEX_NAME:-idx:canvas}*" resetchannels -@all \
        +auth +ping +role +json.get +json.set +json.arrlen +json.arrappend +json.del \
        +get +del +exists +keys +eval +ft.search +ft.info
      ;;
    *)
      echo "Unsupported Redis authentication mode: $mode" >&2
      exit 2
      ;;
  esac
' redis-container-cli "$MODE" "$@"
