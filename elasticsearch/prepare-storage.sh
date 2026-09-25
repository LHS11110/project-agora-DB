#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi
SNAPSHOT_DIR="${ES_SNAPSHOT_HOST_DIR:-$SCRIPT_DIR/snapshots}"
case "$SNAPSHOT_DIR" in /*) ;; *) SNAPSHOT_DIR="$SCRIPT_DIR/$SNAPSHOT_DIR" ;; esac
CERT_DIR="${ES_TLS_CERTS_DIR:-$SCRIPT_DIR/certs}"
case "$CERT_DIR" in /*) ;; *) CERT_DIR="$SCRIPT_DIR/$CERT_DIR" ;; esac

sudo install -d -o "${ES_CONTAINER_UID:-1000}" -g "${ES_CONTAINER_GID:-0}" -m 0770 "$SNAPSHOT_DIR"
install -d -m 0750 "$CERT_DIR"
if [ -f "$SCRIPT_DIR/.env" ]; then chmod 600 "$SCRIPT_DIR/.env"; fi
echo "Snapshot directory prepared for Elasticsearch UID ${ES_CONTAINER_UID:-1000}: $SNAPSHOT_DIR"
echo "Place the HTTP certificate, private key, and CA in: $CERT_DIR"
