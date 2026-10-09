#!/usr/bin/env bash
# Runs as root inside the helper container, with certificate input read-only.
set -euo pipefail
if [ "${ES_HTTP_TLS_ENABLED:-true}" != true ]; then
  echo "Elasticsearch requires TLS; ES_HTTP_TLS_ENABLED must be true." >&2
  exit 1
fi
for name in http.crt http.key ca.crt; do
  [ -f "/source/$name" ] && [ ! -L "/source/$name" ] \
    || { echo "Elasticsearch TLS input is missing or is a symlink: $name" >&2; exit 1; }
  [ ! -L "/target/$name" ] || { echo 'Refusing a symlink in the TLS volume' >&2; exit 1; }
done
TEMP_FILE=""
trap 'if [ -n "$TEMP_FILE" ]; then rm -f "$TEMP_FILE"; fi' EXIT
for name in http.crt http.key ca.crt; do
  TEMP_FILE="$(mktemp /target/.tls-copy.XXXXXX)"
  cp "/source/$name" "$TEMP_FILE"
  chown 1000:0 "$TEMP_FILE"
  case "$name" in *.key) chmod 0600 "$TEMP_FILE" ;; *) chmod 0644 "$TEMP_FILE" ;; esac
  mv -f "$TEMP_FILE" "/target/$name"
  TEMP_FILE=""
done
chown 1000:0 /target
chmod 0750 /target
