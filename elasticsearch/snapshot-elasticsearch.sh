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
ES_HOST="${ES_HOST:-${ES_EXTERNAL_IP:-127.0.0.1}}"
case "$ES_HOST" in 0.0.0.0|::) ES_HOST=127.0.0.1 ;; esac
ES_SCHEME="${ES_SCHEME:-http}"
ES_PORT="${ES_EXTERNAL_PORT:-${ES_PORT:-9200}}"
ES_URL="${ES_SCHEME}://${ES_HOST}:${ES_PORT}"
REPOSITORY="${ES_SNAPSHOT_REPOSITORY:-agora-filesystem}"
INDEX_NAME="${ES_INDEX:-canvas}"
LOG_INDEX="${ES_LOG_INDEX:-agora-logs}"
SNAPSHOT_NAME="agora-manual-$(date -u +%Y%m%dT%H%M%SZ)"
CURL_ARGS=(-sS -f -u "elastic:${ELASTIC_PASSWORD}")
if [ -n "${ES_CA_CERT:-}" ]; then CURL_ARGS+=(--cacert "$ES_CA_CERT"); fi

curl "${CURL_ARGS[@]}" -X PUT "$ES_URL/_snapshot/$REPOSITORY" \
  -H 'Content-Type: application/json' \
  -d '{"type":"fs","settings":{"location":"/usr/share/elasticsearch/snapshots","compress":true}}' >/dev/null
curl "${CURL_ARGS[@]}" -X PUT "$ES_URL/_snapshot/$REPOSITORY/$SNAPSHOT_NAME?wait_for_completion=true" \
  -H 'Content-Type: application/json' \
  -d "{\"indices\":\"${INDEX_NAME},${LOG_INDEX}\",\"include_global_state\":false,\"ignore_unavailable\":true}" >/dev/null
echo "Elasticsearch snapshot saved: $SNAPSHOT_NAME"
