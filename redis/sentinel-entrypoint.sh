#!/bin/sh
set -eu
umask 077

: "${REDIS_PASSWORD:?REDIS_PASSWORD must be set in redis/.env}"
CONFIG_FILE=/data/sentinel.conf
ACL_FILE=/data/sentinel-users.acl
MASTER_HOST="${REDIS_SENTINEL_MASTER_HOST:-redis-primary}"
SENTINEL_BIND_IP="${REDIS_SENTINEL_BIND_IP:-0.0.0.0}"
SENTINEL_PORT="${REDIS_SENTINEL_PORT:-26379}"
NODE_PORT="${REDIS_NODE_PORT:-6379}"
TLS_ENABLED="${REDIS_TLS_ENABLED:-false}"
TLS_CERTIFICATE="${REDIS_TLS_CERTIFICATE:-/run/secrets/redis-tls/server.crt}"
TLS_KEY="${REDIS_TLS_KEY:-/run/secrets/redis-tls/server.key}"
TLS_CA_CERT="${REDIS_TLS_CA_CERT:-/run/secrets/redis-tls/ca.crt}"
ESCAPED_PASSWORD=$(printf '%s' "$REDIS_PASSWORD" | sed 's/\\/\\\\/g; s/"/\\"/g')
PASSWORD_HASH=$(printf '%s' "$REDIS_PASSWORD" | sha256sum | awk '{print $1}')

SENTINEL_ACL="user default on nopass -@all +auth +client|getname +client|id +client|setname +client|setinfo +command +hello +ping +role +sentinel|get-master-addr-by-name +sentinel|master +sentinel|myid +sentinel|replicas +sentinel|sentinels +sentinel|masters"
if [ -n "${REDIS_SENTINEL_USER:-}" ] || [ -n "${REDIS_SENTINEL_PASSWORD:-}" ]; then
  : "${REDIS_SENTINEL_USER:?REDIS_SENTINEL_USER is required with REDIS_SENTINEL_PASSWORD}"
  : "${REDIS_SENTINEL_PASSWORD:?REDIS_SENTINEL_PASSWORD is required with REDIS_SENTINEL_USER}"
  case "$REDIS_SENTINEL_USER" in
    *[!A-Za-z0-9_.-]*) echo "REDIS_SENTINEL_USER contains unsupported ACL username characters." >&2; exit 1 ;;
  esac
  SENTINEL_PASSWORD_HASH=$(printf '%s' "$REDIS_SENTINEL_PASSWORD" | sha256sum | awk '{print $1}')
  SENTINEL_ACL="user default off
user $REDIS_SENTINEL_USER on #$SENTINEL_PASSWORD_HASH -@all +auth +ping \
+sentinel|get-master-addr-by-name +sentinel|masters +sentinel|master \
+sentinel|replicas +sentinel|sentinels +sentinel|myid"
fi
case "$TLS_ENABLED" in
  true|false) ;;
  *) echo "REDIS_TLS_ENABLED must be true or false." >&2; exit 1 ;;
esac
if [ "$TLS_ENABLED" = true ]; then
  for tls_file in "$TLS_CERTIFICATE" "$TLS_KEY" "$TLS_CA_CERT"; do
    if [ ! -r "$tls_file" ]; then
      echo "Redis Sentinel TLS file is not readable: $tls_file" >&2
      exit 1
    fi
  done
  TLS_RUNTIME_DIR=/data/tls
  mkdir -p "$TLS_RUNTIME_DIR"
  cp "$TLS_CERTIFICATE" "$TLS_RUNTIME_DIR/server.crt"
  cp "$TLS_KEY" "$TLS_RUNTIME_DIR/server.key"
  cp "$TLS_CA_CERT" "$TLS_RUNTIME_DIR/ca.crt"
  chown -R redis:redis "$TLS_RUNTIME_DIR"
  chmod 0700 "$TLS_RUNTIME_DIR/server.key"
  chmod 0644 "$TLS_RUNTIME_DIR/server.crt" "$TLS_RUNTIME_DIR/ca.crt"
  TLS_CERTIFICATE="$TLS_RUNTIME_DIR/server.crt"
  TLS_KEY="$TLS_RUNTIME_DIR/server.key"
  TLS_CA_CERT="$TLS_RUNTIME_DIR/ca.crt"
fi
cat > "$ACL_FILE" <<EOF
$SENTINEL_ACL
user sentinel-internal on #$PASSWORD_HASH allchannels +@all
EOF
chmod 600 "$ACL_FILE"

if [ ! -s "$CONFIG_FILE" ]; then
  if [ "$TLS_ENABLED" = true ]; then
    cat > "$CONFIG_FILE" <<EOF
port 0
tls-port $SENTINEL_PORT
tls-cert-file $TLS_CERTIFICATE
tls-key-file $TLS_KEY
tls-ca-cert-file $TLS_CA_CERT
tls-auth-clients no
tls-replication yes
tls-protocols TLSv1.2 TLSv1.3
EOF
  else
    cat > "$CONFIG_FILE" <<EOF
port $SENTINEL_PORT
EOF
  fi
  cat >> "$CONFIG_FILE" <<EOF
bind $SENTINEL_BIND_IP
protected-mode yes
dir /data
aclfile $ACL_FILE
sentinel resolve-hostnames yes
sentinel announce-hostnames no
sentinel monitor agora-master $MASTER_HOST $NODE_PORT 2
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

# Sentinel rewrites discovered replica addresses into sentinel.conf. Older
# configurations may contain Docker hostnames while announce-hostnames is
# disabled. Redis then resolves that hostname to an IP and can reject the
# persisted hostname/IP pair as a duplicate endpoint on restart. Clients and
# peers need the routable numeric address, so retain numeric replica records
# and let Sentinel rediscover hostname records from the monitored primary.
CONFIG_TEMP="${CONFIG_FILE}.tmp"
awk '
  $1 == "sentinel" && $2 == "known-replica" {
    host = $4
    numeric_address = host ~ /^[0-9][0-9.]*$/ \
      || (host ~ /^[[:xdigit:]:]+$/ && host ~ /:/)
    key = $3 " " host " " $5
    if (!numeric_address || seen[key]++) next
  }
  { print }
' "$CONFIG_FILE" > "$CONFIG_TEMP"
mv "$CONFIG_TEMP" "$CONFIG_FILE"

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
set_config_line 'sentinel announce-hostnames ' 'sentinel announce-hostnames no'
set_config_line 'sentinel auth-pass agora-master ' "sentinel auth-pass agora-master \"$ESCAPED_PASSWORD\""
set_config_line 'sentinel sentinel-user ' 'sentinel sentinel-user sentinel-internal'
set_config_line 'sentinel sentinel-pass ' "sentinel sentinel-pass \"$ESCAPED_PASSWORD\""
if [ "$TLS_ENABLED" = true ]; then
  set_config_line 'port ' 'port 0'
  set_config_line 'tls-port ' "tls-port $SENTINEL_PORT"
  set_config_line 'tls-cert-file ' "tls-cert-file $TLS_CERTIFICATE"
  set_config_line 'tls-key-file ' "tls-key-file $TLS_KEY"
  set_config_line 'tls-ca-cert-file ' "tls-ca-cert-file $TLS_CA_CERT"
  set_config_line 'tls-auth-clients ' 'tls-auth-clients no'
  set_config_line 'tls-replication ' 'tls-replication yes'
  set_config_line 'tls-protocols ' 'tls-protocols TLSv1.2 TLSv1.3'
else
  set_config_line 'port ' "port $SENTINEL_PORT"
  sed -i '/^tls-port /d; /^tls-cert-file /d; /^tls-key-file /d; /^tls-ca-cert-file /d; /^tls-auth-clients /d; /^tls-replication /d; /^tls-protocols /d' "$CONFIG_FILE"
fi
if grep -q '^bind ' "$CONFIG_FILE"; then
  sed -i "s|^bind .*|bind $SENTINEL_BIND_IP|" "$CONFIG_FILE"
else
  printf 'bind %s\n' "$SENTINEL_BIND_IP" >> "$CONFIG_FILE"
fi
chmod 600 "$CONFIG_FILE"

chown redis:redis "$ACL_FILE" "$CONFIG_FILE"
exec /usr/local/bin/docker-entrypoint.sh redis-server "$CONFIG_FILE" --sentinel
