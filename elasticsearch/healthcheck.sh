#!/usr/bin/env bash
set -euo pipefail

: "${ELASTIC_PASSWORD:?ELASTIC_PASSWORD is required}"
source /usr/local/bin/curl-auth.sh

CURL_ARGS=(-sS -f)
if [ "${ES_HTTP_TLS_ENABLED:-false}" = "true" ]; then
  CURL_ARGS+=(--cacert /usr/share/elasticsearch/config/certs/ca.crt)
  ES_URL=https://localhost:9200/_cluster/health
else
  ES_URL=http://localhost:9200/_cluster/health
fi

es_curl_authenticated elastic "$ELASTIC_PASSWORD" "${CURL_ARGS[@]}" "$ES_URL" >/dev/null
