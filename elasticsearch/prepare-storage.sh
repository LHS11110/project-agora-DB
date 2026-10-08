#!/usr/bin/env bash
# Use the Linux image's ownership tools; no host sudo/GNU install dependency.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  source "$SCRIPT_DIR/.env"
  set +a
fi
SNAPSHOT_DIR="${ES_SNAPSHOT_HOST_DIR:-$SCRIPT_DIR/snapshots}"
case "$SNAPSHOT_DIR" in /*) ;; *) SNAPSHOT_DIR="$SCRIPT_DIR/$SNAPSHOT_DIR" ;; esac
CERT_DIR="${ES_TLS_CERTS_DIR:-$SCRIPT_DIR/certs}"
case "$CERT_DIR" in /*) ;; *) CERT_DIR="$SCRIPT_DIR/$CERT_DIR" ;; esac
for directory in "$SNAPSHOT_DIR" "$CERT_DIR"; do
  [ ! -L "$directory" ] || { echo "Refusing a symlinked storage directory" >&2; exit 1; }
  mkdir -p "$directory"
done
command -v docker >/dev/null 2>&1 || { echo "Docker is required to prepare container file permissions" >&2; exit 127; }
docker info >/dev/null 2>&1 || { echo "Docker engine is unavailable or access is denied" >&2; exit 1; }
CONTAINER_UID="${ES_CONTAINER_UID:-1000}"
CONTAINER_GID="${ES_CONTAINER_GID:-0}"
[[ "$CONTAINER_UID" =~ ^[0-9]+$ && "$CONTAINER_GID" =~ ^[0-9]+$ ]] || { echo "Container UID/GID must be numeric" >&2; exit 2; }
docker run --rm --user 0 --entrypoint /bin/bash \
  --mount "type=bind,src=$SNAPSHOT_DIR,dst=/storage" \
  docker.elastic.co/elasticsearch/elasticsearch:8.19.22 -c '
  set -euo pipefail
  uid="$1"; gid="$2"
  chown "$uid:$gid" /storage
  chmod 0770 /storage
' prepare-storage "$CONTAINER_UID" "$CONTAINER_GID"
docker compose --project-directory "$SCRIPT_DIR" --env-file "$SCRIPT_DIR/.env" \
  -f "$SCRIPT_DIR/docker-compose.yml" run --rm --no-deps elasticsearch-tls-init
if [ -f "$SCRIPT_DIR/.env" ]; then chmod 600 "$SCRIPT_DIR/.env"; fi
echo "Elasticsearch snapshot permissions and private TLS volume prepared; host key ownership preserved."
