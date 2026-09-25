#!/usr/bin/env bash
set -euo pipefail

# Set ES_ALLOW_LOG_INDEX_MIGRATION=true only after stopping every BE instance
# that writes ES_LOG_INDEX. A snapshot is created before the atomic alias swap.
if [ "${ES_ALLOW_LOG_INDEX_MIGRATION:-false}" != "true" ]; then
  echo "Set ES_ALLOW_LOG_INDEX_MIGRATION=true after stopping all log writers." >&2
  exit 2
fi
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
LOG_INDEX="${ES_LOG_INDEX:-agora-logs}"
INDEX_NAME="${ES_INDEX:-canvas}"
POLICY="${ES_LOG_RETENTION_POLICY:-agora-logs-retention}"
REPOSITORY="${ES_SNAPSHOT_REPOSITORY:-agora-filesystem}"
NEW_INDEX="${LOG_INDEX}-000001"
CURL_ARGS=(-sS -f -u "elastic:${ELASTIC_PASSWORD}")
if [ -n "${ES_CA_CERT:-}" ]; then CURL_ARGS+=(--cacert "$ES_CA_CERT"); fi

ALIAS_STATUS=$(curl "${CURL_ARGS[@]}" -o /dev/null -w '%{http_code}' "$ES_URL/_alias/$LOG_INDEX" || true)
if [ "$ALIAS_STATUS" = "200" ]; then
  echo "$LOG_INDEX is already an alias; no migration required."
  exit 0
fi
INDEX_STATUS=$(curl "${CURL_ARGS[@]}" -o /dev/null -w '%{http_code}' "$ES_URL/$LOG_INDEX" || true)
if [ "$INDEX_STATUS" != "200" ]; then
  echo "No concrete log index named $LOG_INDEX exists (HTTP $INDEX_STATUS)." >&2
  exit 1
fi
if [ "$(curl "${CURL_ARGS[@]}" -o /dev/null -w '%{http_code}' "$ES_URL/$NEW_INDEX" || true)" = "200" ]; then
  echo "Target index $NEW_INDEX already exists; inspect it before retrying." >&2
  exit 1
fi

curl "${CURL_ARGS[@]}" -X PUT "$ES_URL/_snapshot/$REPOSITORY" \
  -H 'Content-Type: application/json' \
  -d '{"type":"fs","settings":{"location":"/usr/share/elasticsearch/snapshots","compress":true}}' >/dev/null
SNAPSHOT_NAME="agora-before-log-ilm-$(date -u +%Y%m%dT%H%M%SZ)"
curl "${CURL_ARGS[@]}" -X PUT "$ES_URL/_snapshot/$REPOSITORY/$SNAPSHOT_NAME?wait_for_completion=true" \
  -H 'Content-Type: application/json' \
  -d "{\"indices\":\"${INDEX_NAME},${LOG_INDEX}\",\"include_global_state\":false,\"ignore_unavailable\":true}" >/dev/null

curl "${CURL_ARGS[@]}" -X PUT "$ES_URL/$NEW_INDEX" \
  -H 'Content-Type: application/json' \
  -d "{\"settings\":{\"number_of_shards\":1,\"number_of_replicas\":0,\"index.lifecycle.name\":\"${POLICY}\",\"index.lifecycle.rollover_alias\":\"${LOG_INDEX}\"}}" >/dev/null
curl "${CURL_ARGS[@]}" -X POST "$ES_URL/_reindex?wait_for_completion=true" \
  -H 'Content-Type: application/json' \
  -d "{\"source\":{\"index\":\"${LOG_INDEX}\"},\"dest\":{\"index\":\"${NEW_INDEX}\",\"op_type\":\"create\"}}" >/dev/null

SOURCE_COUNT=$(curl "${CURL_ARGS[@]}" "$ES_URL/$LOG_INDEX/_count" | python3 -c 'import json,sys; print(json.load(sys.stdin)["count"])')
TARGET_COUNT=$(curl "${CURL_ARGS[@]}" "$ES_URL/$NEW_INDEX/_count" | python3 -c 'import json,sys; print(json.load(sys.stdin)["count"])')
if [ "$SOURCE_COUNT" != "$TARGET_COUNT" ]; then
  echo "Reindex count mismatch ($SOURCE_COUNT vs $TARGET_COUNT); original index remains active." >&2
  exit 1
fi

curl "${CURL_ARGS[@]}" -X POST "$ES_URL/_aliases" \
  -H 'Content-Type: application/json' \
  -d "{\"actions\":[{\"remove_index\":{\"index\":\"${LOG_INDEX}\"}},{\"add\":{\"index\":\"${NEW_INDEX}\",\"alias\":\"${LOG_INDEX}\",\"is_write_index\":true}}]}" >/dev/null
echo "Log index migration complete; snapshot=$SNAPSHOT_NAME documents=$TARGET_COUNT alias=$LOG_INDEX"
