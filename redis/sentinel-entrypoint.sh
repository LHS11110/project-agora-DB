#!/bin/sh
set -eu
umask 077

: "${REDIS_PASSWORD:?REDIS_PASSWORD must be set in redis/.env}"
CONFIG_FILE=/data/sentinel.conf
ACL_FILE=/data/sentinel-users.acl
MASTER_HOST="${REDIS_SENTINEL_MASTER_HOST:-redis-primary}"
SENTINEL_BIND_IP="${REDIS_SENTINEL_BIND_IP:-0.0.0.0}"
ESCAPED_PASSWORD=$(printf '%s' "$REDIS_PASSWORD" | sed 's/\\/\\\\/g; s/"/\\"/g')
PASSWORD_HASH=$(printf '%s' "$REDIS_PASSWORD" | sha256sum | awk '{print $1}')

# Existing backend clients query Sentinel without AUTH. Keep discovery
# read-only while requiring the Redis admin credential for Sentinel peers.
cat > "$ACL_FILE" <<EOF
user default on nopass -@all +auth +client|getname +client|id +client|setname +client|setinfo +command +hello +ping +role +sentinel|get-master-addr-by-name +sentinel|master +sentinel|myid +sentinel|replicas +sentinel|sentinels +sentinel|masters
user sentinel-internal on #$PASSWORD_HASH allchannels +@all
EOF
chmod 600 "$ACL_FILE"

if [ ! -s "$CONFIG_FILE" ]; then
  cat > "$CONFIG_FILE" <<EOF
port 26379
bind $SENTINEL_BIND_IP
protected-mode yes
dir /data
aclfile $ACL_FILE
sentinel resolve-hostnames yes
sentinel announce-hostnames yes
sentinel monitor agora-master $MASTER_HOST 6379 2
sentinel auth-pass agora-master "$ESCAPED_PASSWORD"
sentinel sentinel-user sentinel-internal
sentinel sentinel-pass "$ESCAPED_PASSWORD"
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

# Persisted volumes keep the old sentinel.conf, so add these settings there
# during an in-place upgrade as well as on a fresh start.
set_config_line() {
  CONFIG_PREFIX="$1"
  CONFIG_REPLACEMENT="$2"
  CONFIG_TEMP="${CONFIG_FILE}.tmp"
  CONFIG_FOUND=false
  : > "$CONFIG_TEMP"
  while IFS= read -r CONFIG_LINE || [ -n "$CONFIG_LINE" ]; do
    case "$CONFIG_LINE" in
      "$CONFIG_PREFIX"*)
        if [ "$CONFIG_FOUND" != true ]; then
          printf '%s\n' "$CONFIG_REPLACEMENT" >> "$CONFIG_TEMP"
          CONFIG_FOUND=true
        fi
        ;;
      *)
        printf '%s\n' "$CONFIG_LINE" >> "$CONFIG_TEMP"
        ;;
    esac
  done < "$CONFIG_FILE"
  if [ "$CONFIG_FOUND" != true ]; then
    printf '%s\n' "$CONFIG_REPLACEMENT" >> "$CONFIG_TEMP"
  fi
  mv "$CONFIG_TEMP" "$CONFIG_FILE"
}
set_config_line 'aclfile ' "aclfile $ACL_FILE"
set_config_line 'sentinel auth-pass agora-master ' "sentinel auth-pass agora-master \"$ESCAPED_PASSWORD\""
set_config_line 'sentinel sentinel-user ' 'sentinel sentinel-user sentinel-internal'
set_config_line 'sentinel sentinel-pass ' "sentinel sentinel-pass \"$ESCAPED_PASSWORD\""
if grep -q '^bind ' "$CONFIG_FILE"; then
  sed -i "s|^bind .*|bind $SENTINEL_BIND_IP|" "$CONFIG_FILE"
else
  printf 'bind %s\n' "$SENTINEL_BIND_IP" >> "$CONFIG_FILE"
fi
chmod 600 "$CONFIG_FILE"

exec redis-server "$CONFIG_FILE" --sentinel
