#!/usr/bin/env bash
# Local development only. Refuse to replace existing certificates or signing keys.
set -euo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="$SCRIPT_DIR/certs"
CA_DIR="$SCRIPT_DIR/.dev-tls"
for file in "$CERT_DIR/http.crt" "$CERT_DIR/http.key" "$CERT_DIR/ca.crt" "$CA_DIR/ca.key"; do
  [ ! -e "$file" ] || { echo 'Development Elasticsearch TLS files already exist; no files were replaced.' >&2; exit 1; }
done
mkdir -p "$CERT_DIR" "$CA_DIR"
chmod 0750 "$CERT_DIR"
chmod 0700 "$CA_DIR"
openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
  -keyout "$CA_DIR/ca.key" -out "$CERT_DIR/ca.crt" \
  -subj '/CN=Project Agora Elasticsearch Development CA' \
  -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign'
openssl req -new -newkey rsa:2048 -nodes -keyout "$CERT_DIR/http.key" \
  -out "$CA_DIR/http.csr" -subj '/CN=agora-elasticsearch'
trap 'rm -f "$CA_DIR/http.csr" "$CA_DIR/http.ext"' EXIT
cat > "$CA_DIR/http.ext" <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:localhost,DNS:agora-elasticsearch,IP:127.0.0.1
EOF
openssl x509 -req -in "$CA_DIR/http.csr" -CA "$CERT_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" \
  -CAserial "$CA_DIR/ca.srl" -CAcreateserial -out "$CERT_DIR/http.crt" -days 825 -sha256 -extfile "$CA_DIR/http.ext"
chmod 0600 "$CA_DIR/ca.key" "$CERT_DIR/http.key"
chmod 0644 "$CERT_DIR/ca.crt" "$CERT_DIR/http.crt"
openssl verify -CAfile "$CERT_DIR/ca.crt" "$CERT_DIR/http.crt" >/dev/null
echo 'Elasticsearch development-only HTTPS certificates created. Run prepare-storage before starting Docker.'
