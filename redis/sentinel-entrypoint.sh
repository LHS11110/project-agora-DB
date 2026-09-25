#!/bin/sh
set -eu

: "${REDIS_PASSWORD:?REDIS_PASSWORD must be set in redis/.env}"
CONFIG_FILE=/data/sentinel.conf
MASTER_HOST="${REDIS_SENTINEL_MASTER_HOST:-redis-primary}"

if [ ! -s "$CONFIG_FILE" ]; then
  ESCAPED_PASSWORD=$(printf '%s' "$REDIS_PASSWORD" | sed 's/\\/\\\\/g; s/"/\\"/g')
  cat > "$CONFIG_FILE" <<EOF
port 26379
bind 0.0.0.0
protected-mode no
dir /data
sentinel resolve-hostnames yes
sentinel announce-hostnames yes
sentinel monitor agora-master $MASTER_HOST 6379 2
sentinel auth-pass agora-master "$ESCAPED_PASSWORD"
sentinel down-after-milliseconds agora-master 5000
sentinel failover-timeout agora-master 60000
sentinel parallel-syncs agora-master 1
EOF
  if [ -n "${REDIS_SENTINEL_ANNOUNCE_IP:-}" ]; then
    printf 'sentinel announce-ip %s\n' "$REDIS_SENTINEL_ANNOUNCE_IP" >> "$CONFIG_FILE"
  fi
fi

if [ -n "${REDIS_SENTINEL_ANNOUNCE_IP:-}" ]; then
  if grep -q '^sentinel announce-ip ' "$CONFIG_FILE"; then
    sed -i "s|^sentinel announce-ip .*|sentinel announce-ip $REDIS_SENTINEL_ANNOUNCE_IP|" "$CONFIG_FILE"
  else
    printf 'sentinel announce-ip %s\n' "$REDIS_SENTINEL_ANNOUNCE_IP" >> "$CONFIG_FILE"
  fi
fi

exec redis-server "$CONFIG_FILE" --sentinel
