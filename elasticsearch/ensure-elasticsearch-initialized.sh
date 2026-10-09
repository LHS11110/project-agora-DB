#!/usr/bin/env bash
# Initialize the canvas index and log alias only when this Elasticsearch volume
# has not been initialized yet. Existing populated indices are left untouched.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/curl-auth.sh"

[[ -f "$SCRIPT_DIR/.env" && ! -L "$SCRIPT_DIR/.env" ]] || {
  printf 'Error: missing or unsafe Elasticsearch environment file: %s/.env\n' "$SCRIPT_DIR" >&2
  exit 1
}
set -a
source "$SCRIPT_DIR/.env"
set +a

: "${ELASTIC_PASSWORD:?ELASTIC_PASSWORD must be set in elasticsearch/.env}"

ES_EXTERNAL_IP="${ES_EXTERNAL_IP:-127.0.0.1}"
if [[ "$ES_EXTERNAL_IP" == "0.0.0.0" ]]; then
  ES_CONNECT_IP="127.0.0.1"
else
  ES_CONNECT_IP="$ES_EXTERNAL_IP"
fi
ES_CONNECT_PORT="${ES_EXTERNAL_PORT:-${ES_PORT:-9200}}"
ES_SCHEME="${ES_SCHEME:-https}"
if [[ "$ES_SCHEME" != "https" ]]; then
  printf 'Error: ES_SCHEME must be https.\n' >&2
  exit 1
fi
ES_HOST="${ES_SCHEME}://${ES_CONNECT_IP}:${ES_CONNECT_PORT}"
ES_INDEX="${ES_INDEX:-canvas}"
ES_LOG_INDEX="${ES_LOG_INDEX:-agora-logs}"
ES_CURL_ARGS=(-sS -o /dev/null -w '%{http_code}')
if [[ -n "${ES_CA_CERT:-}" ]]; then
  ES_CURL_ARGS+=(--cacert "$ES_CA_CERT")
fi

request_status() {
  local path="$1"
  es_curl_authenticated elastic "$ELASTIC_PASSWORD" \
    ${ES_CURL_ARGS[@]+"${ES_CURL_ARGS[@]}"} "$ES_HOST$path"
}

if ! auth_status="$(request_status '/_security/_authenticate')"; then
  printf 'Error: could not reach Elasticsearch at %s.\n' "$ES_HOST" >&2
  exit 1
fi
[[ "$auth_status" == "200" ]] || {
  printf 'Error: Elasticsearch authentication failed (HTTP %s). Check elasticsearch/.env.\n' "$auth_status" >&2
  exit 1
}

if ! index_status="$(request_status "/$ES_INDEX")"; then
  printf 'Error: could not check Elasticsearch index initialization.\n' >&2
  exit 1
fi
if ! alias_status="$(request_status "/_alias/$ES_LOG_INDEX")"; then
  printf 'Error: could not check Elasticsearch log alias initialization.\n' >&2
  exit 1
fi

if [[ "$index_status" == "200" && "$alias_status" == "200" ]]; then
  printf 'Elasticsearch canvas index and log alias are already initialized.\n'
  exit 0
fi
if [[ "$index_status" != "200" && "$index_status" != "404" ]]; then
  printf 'Error: Elasticsearch index check failed (HTTP %s).\n' "$index_status" >&2
  exit 1
fi
if [[ "$alias_status" != "200" && "$alias_status" != "404" ]]; then
  printf 'Error: Elasticsearch log alias check failed (HTTP %s).\n' "$alias_status" >&2
  exit 1
fi

printf 'Elasticsearch initialization is incomplete; applying the repository index and log schema.\n'
"$SCRIPT_DIR/init-elasticsearch.sh"
