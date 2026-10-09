#!/usr/bin/env bash
set -euo pipefail

if [ "${MSSQL_TLS_ENABLED:-true}" != "true" ]; then
  echo "SQL Server requires MSSQL_TLS_ENABLED=true." >&2
  exit 1
fi
if [ "${MSSQL_TLS_ENABLED:-true}" = "true" ]; then
  TLS_CERT="${MSSQL_TLS_CERTIFICATE:-/run/secrets/mssql-tls/server.crt}"
  TLS_KEY="${MSSQL_TLS_KEY:-/run/secrets/mssql-tls/server.key}"
  if [ ! -r "$TLS_CERT" ] || [ ! -r "$TLS_KEY" ]; then
    echo "MSSQL_TLS_ENABLED=true requires readable TLS certificate and key files." >&2
    exit 1
  fi
  # Write the owned SQL configuration without requiring a root process.
  export TLS_CERT TLS_KEY
  python3 - <<'CONF'
import configparser, os
from pathlib import Path
path = Path('/var/opt/mssql/mssql.conf')
config = configparser.ConfigParser()
config.read(path)
if not config.has_section('network'): config.add_section('network')
for key, value in {'tlscert': os.environ['TLS_CERT'], 'tlskey': os.environ['TLS_KEY'], 'tlsprotocols': '1.2', 'forceencryption': '1'}.items():
    config.set('network', key, value)
with path.open('w') as output: config.write(output)
CONF
fi

# Preserve Microsoft's image UID and writable-volume checks after TLS setup.
# Recent SQL Server images print their non-root/volume check and exit without
# forwarding the command, so launch sqlservr after the check completes.
/opt/mssql/bin/permissions_check.sh "$@"
exec "$@"
