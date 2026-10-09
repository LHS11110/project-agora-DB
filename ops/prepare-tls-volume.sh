#!/bin/sh
# Copy manually supplied leaf material into a service-owned volume.
set -eu
umask 077
uid="${1:?service UID is required}"
cert="${2:?certificate filename is required}"
key="${3:?private key filename is required}"
ca="${4:?CA filename is required}"
for file in "$cert" "$key" "$ca"; do
  if [ ! -s "/source/$file" ] || [ -L "/source/$file" ]; then
    echo "Missing or unsafe manually supplied TLS file: /source/$file" >&2
    exit 1
  fi
done
mkdir -p /target
for file in fullchain.pem privkey.pem ca.pem; do
  if [ -L "/target/$file" ]; then
    echo "Refusing a symlink in the TLS volume: $file" >&2
    exit 1
  fi
done
cp "/source/$cert" /target/fullchain.pem
cp "/source/$key" /target/privkey.pem
cp "/source/$ca" /target/ca.pem
chown "$uid:$uid" /target /target/fullchain.pem /target/privkey.pem /target/ca.pem
chmod 750 /target
chmod 600 /target/privkey.pem
chmod 644 /target/fullchain.pem /target/ca.pem
