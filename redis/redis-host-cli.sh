#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi

MODE="${1:?Usage: redis-host-cli.sh admin|app [redis-cli args...]}"
shift
command -v redis-cli >/dev/null 2>&1 || { echo "redis-cli is required on the host" >&2; exit 127; }

TLS_ARGS=()
if [ "${REDIS_TLS_ENABLED:-false}" = true ]; then
  REDIS_TLS_CA_CERT_HOST="${REDIS_TLS_CA_CERT_HOST:-${REDIS_TLS_CA_CERT:-}}"
  : "${REDIS_TLS_CA_CERT_HOST:?REDIS_TLS_CA_CERT_HOST must point to the host-readable Redis CA}"
  [ -r "$REDIS_TLS_CA_CERT_HOST" ] || { echo "Redis TLS CA is not readable" >&2; exit 1; }
  TLS_ARGS=(--tls --cacert "$REDIS_TLS_CA_CERT_HOST")
fi

REDIS_HOST="${REDIS_CONNECT_HOST:-${REDIS_BIND_IP:-127.0.0.1}}"
if [ "$REDIS_HOST" = "0.0.0.0" ]; then REDIS_HOST=127.0.0.1; fi
REDIS_PORT="${REDIS_CONNECT_PORT:-${REDIS_EXTERNAL_PORT:-${REDIS_PORT:-6379}}}"

if [ -n "${REDIS_SENTINELS:-}" ]; then
  : "${REDIS_SENTINEL_MASTER_NAME:=agora-master}"
  : "${REDIS_SENTINEL_USER:?REDIS_SENTINEL_USER is required with REDIS_SENTINELS}"
  : "${REDIS_SENTINEL_PASSWORD:?REDIS_SENTINEL_PASSWORD is required with REDIS_SENTINELS}"
  MASTER_HOST=""
  MASTER_PORT=""
  IFS=',' read -r -a SEEDS <<< "$REDIS_SENTINELS"
  for seed in "${SEEDS[@]}"; do
    seed="${seed//[[:space:]]/}"
    if [[ "$seed" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
      SENTINEL_HOST="${BASH_REMATCH[1]}"
      SENTINEL_PORT="${BASH_REMATCH[2]}"
    elif [[ "$seed" =~ ^([^:]+):([0-9]+)$ ]]; then
      SENTINEL_HOST="${BASH_REMATCH[1]}"
      SENTINEL_PORT="${BASH_REMATCH[2]}"
    else
      continue
    fi
    if MASTER_INFO="$(REDISCLI_AUTH="$REDIS_SENTINEL_PASSWORD" redis-cli "${TLS_ARGS[@]}" \
      --raw -h "$SENTINEL_HOST" -p "$SENTINEL_PORT" --user "$REDIS_SENTINEL_USER" \
      --no-auth-warning SENTINEL get-master-addr-by-name "$REDIS_SENTINEL_MASTER_NAME" 2>/dev/null)"; then
      MASTER_HOST="$(printf '%s\n' "$MASTER_INFO" | sed -n '1p' | tr -d '\r')"
      MASTER_PORT="$(printf '%s\n' "$MASTER_INFO" | sed -n '2p' | tr -d '\r')"
      if [ -n "$MASTER_HOST" ] && [[ "$MASTER_PORT" =~ ^[0-9]+$ ]]; then break; fi
    fi
  done
  if [ -z "$MASTER_HOST" ] || [ -z "$MASTER_PORT" ]; then
    echo "Could not discover the Redis primary from configured Sentinels" >&2
    exit 1
  fi
  REDIS_HOST="$MASTER_HOST"
  REDIS_PORT="$MASTER_PORT"
fi

case "$MODE" in
  admin)
    : "${REDIS_PASSWORD:?REDIS_PASSWORD is required}"
    REDISCLI_AUTH="$REDIS_PASSWORD" exec redis-cli "${TLS_ARGS[@]}" -h "$REDIS_HOST" -p "$REDIS_PORT" "$@"
    ;;
  app)
    : "${REDIS_USER_PASSWORD:?REDIS_USER_PASSWORD is required}"
    REDISCLI_AUTH="$REDIS_USER_PASSWORD" exec redis-cli "${TLS_ARGS[@]}" -h "$REDIS_HOST" -p "$REDIS_PORT" \
      --user "${REDIS_USER:-agora_user}" --no-auth-warning "$@"
    ;;
  *) echo "Unsupported Redis host CLI mode: $MODE" >&2; exit 2 ;;
esac
