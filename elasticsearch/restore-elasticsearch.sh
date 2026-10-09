#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/.env"
  set +a
fi
: "${ELASTIC_PASSWORD:?ELASTIC_PASSWORD is required}"
source "$SCRIPT_DIR/curl-auth.sh"
: "${ES_RESTORE_SNAPSHOT:?Set ES_RESTORE_SNAPSHOT to the exact snapshot name}"
ES_HOST="${ES_HOST:-${ES_EXTERNAL_IP:-127.0.0.1}}"
case "$ES_HOST" in 0.0.0.0|::) ES_HOST=127.0.0.1 ;; esac
ES_SCHEME="${ES_SCHEME:-https}"
ES_PORT="${ES_EXTERNAL_PORT:-${ES_PORT:-9200}}"
ES_URL="${ES_SCHEME}://${ES_HOST}:${ES_PORT}"
REPOSITORY="${ES_SNAPSHOT_REPOSITORY:-agora-filesystem}"
INDEX_NAME="${ES_INDEX:-canvas}"
LOG_INDEX="${ES_LOG_INDEX:-agora-logs}"
ES_CURL_TLS_ARGS=()
if [ -n "${ES_CA_CERT:-}" ]; then ES_CURL_TLS_ARGS+=(--cacert "$ES_CA_CERT"); fi
curl_es() { es_curl_authenticated elastic "$ELASTIC_PASSWORD" ${ES_CURL_TLS_ARGS[@]+"${ES_CURL_TLS_ARGS[@]}"} "$@"; }

# Restore into an empty recovery deployment. This script never deletes or
# overwrites existing indices; resolve naming conflicts before using it.
curl_es -sS -f -X POST \
  "$ES_URL/_snapshot/$REPOSITORY/$ES_RESTORE_SNAPSHOT/_restore?wait_for_completion=true" \
  -H 'Content-Type: application/json' \
  -d "{\"indices\":\"${INDEX_NAME},${LOG_INDEX},${LOG_INDEX}-*\",\"include_global_state\":false,\"include_aliases\":true,\"ignore_unavailable\":true}" >/dev/null
echo "Elasticsearch restore request completed from snapshot $ES_RESTORE_SNAPSHOT"
