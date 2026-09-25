#!/usr/bin/env bash
set -euo pipefail

if [ "${MSSQL_TLS_ENABLED:-false}" = "true" ]; then
  TLS_CERT="${MSSQL_TLS_CERTIFICATE:-/run/secrets/mssql-tls/server.crt}"
  TLS_KEY="${MSSQL_TLS_KEY:-/run/secrets/mssql-tls/server.key}"
  if [ ! -r "$TLS_CERT" ] || [ ! -r "$TLS_KEY" ]; then
    echo "MSSQL_TLS_ENABLED=true requires readable TLS certificate and key files." >&2
    exit 1
  fi
  /opt/mssql/bin/mssql-conf set network.tlscert "$TLS_CERT"
  /opt/mssql/bin/mssql-conf set network.tlskey "$TLS_KEY"
  /opt/mssql/bin/mssql-conf set network.tlsprotocols 1.2
  /opt/mssql/bin/mssql-conf set network.forceencryption 1
fi

# Preserve Microsoft's image UID and writable-volume checks after TLS setup.
exec /opt/mssql/bin/permissions_check.sh "$@"
