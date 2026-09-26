#!/usr/bin/env bash
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/tls"
SERVER_DIR="$ROOT_DIR/server"
FORCE=false
if [ "${1:-}" = "--force" ]; then FORCE=true; shift; fi
if [ "$#" -ne 0 ]; then
  echo "Usage: $0 [--force]" >&2
  exit 2
fi

if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi

if [ -e "$ROOT_DIR/ca.key" ] || [ -e "$ROOT_DIR/ca.crt" ] \
    || [ -e "$SERVER_DIR/server.key" ] || [ -e "$SERVER_DIR/server.crt" ]; then
  if [ "$FORCE" != true ]; then
    echo "Development Redis TLS files already exist; pass --force to replace them." >&2
    exit 1
  fi
  rm -f "$ROOT_DIR/ca.key" "$ROOT_DIR/ca.crt" "$ROOT_DIR/ca.srl" \
    "$SERVER_DIR/server.key" "$SERVER_DIR/server.crt" "$SERVER_DIR/ca.crt"
fi

mkdir -p "$SERVER_DIR"
chmod 0755 "$ROOT_DIR"
chmod 0755 "$SERVER_DIR"

SAN="DNS:localhost,DNS:redis-primary,DNS:redis-replica-1,DNS:redis-replica-2,DNS:agora-redis-primary,DNS:agora-redis-replica-1,DNS:agora-redis-replica-2,IP:127.0.0.1"
declare -A seen_ip=()
for ip in \
  "${REDIS_PRIMARY_IP:-172.20.0.2}" \
  "${REDIS_REPLICA_1_IP:-172.20.0.7}" \
  "${REDIS_REPLICA_2_IP:-172.20.0.5}" \
  "${REDIS_SENTINEL_1_IP:-172.20.0.6}" \
  "${REDIS_SENTINEL_2_IP:-172.20.0.3}" \
  "${REDIS_SENTINEL_3_IP:-172.20.0.4}"; do
  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && [ -z "${seen_ip[$ip]:-}" ]; then
    SAN+=" ,IP:$ip"
    seen_ip[$ip]=1
  fi
done
SAN="${SAN// /}"

EXT_FILE="$SERVER_DIR/server.ext"
CSR_FILE="$SERVER_DIR/server.csr"
trap 'rm -f "$EXT_FILE" "$CSR_FILE"' EXIT

openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
  -keyout "$ROOT_DIR/ca.key" -out "$ROOT_DIR/ca.crt" \
  -subj "/CN=Project Agora Redis Development CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"
openssl req -new -newkey rsa:2048 -nodes \
  -keyout "$SERVER_DIR/server.key" -out "$CSR_FILE" \
  -subj "/CN=agora-redis"
cat > "$EXT_FILE" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=$SAN
EOF
openssl x509 -req -in "$CSR_FILE" -CA "$ROOT_DIR/ca.crt" -CAkey "$ROOT_DIR/ca.key" \
  -CAcreateserial -out "$SERVER_DIR/server.crt" -days 825 -sha256 -extfile "$EXT_FILE"
cp "$ROOT_DIR/ca.crt" "$SERVER_DIR/ca.crt"

chmod 0600 "$SERVER_DIR/server.key"
chmod 0644 "$SERVER_DIR/server.crt" "$SERVER_DIR/ca.crt" "$ROOT_DIR/ca.crt"
chmod 0600 "$ROOT_DIR/ca.key"
openssl verify -CAfile "$ROOT_DIR/ca.crt" "$SERVER_DIR/server.crt" >/dev/null

echo "Created development-only Redis/Sentinel TLS certificates in $ROOT_DIR."
echo "The Redis private key is copied into each data volume with Redis-only permissions at startup."
