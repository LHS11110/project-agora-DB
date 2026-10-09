#!/usr/bin/env bash
set -euo pipefail

: "${ELASTIC_PASSWORD:?ELASTIC_PASSWORD is required}"
source /usr/local/bin/curl-auth.sh

CURL_ARGS=(-sS -f --cacert /usr/share/elasticsearch/config/certs/ca.crt)
ES_URL=https://localhost:9200/_cluster/health

es_curl_authenticated elastic "$ELASTIC_PASSWORD" ${CURL_ARGS[@]+"${CURL_ARGS[@]}"} "$ES_URL" >/dev/null
