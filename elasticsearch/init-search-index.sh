#!/usr/bin/env bash
# Create a disposable metadata projection, never recreate the authoritative canvas index.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT/curl-auth.sh"
set -a
source "$ROOT/.env"
set +a
[[ "${ES_SCHEME:-https}" == https ]] || { echo 'HTTPS is required.' >&2; exit 1; }
host="${ES_EXTERNAL_IP:-127.0.0.1}"
[[ "$host" != 0.0.0.0 ]] || host=127.0.0.1
endpoint="https://${host}:${ES_EXTERNAL_PORT:-${ES_PORT:-9200}}"
alias_name="${ES_SEARCH_INDEX:-canvas-search}"
[[ "$alias_name" =~ ^[a-z][a-z0-9_-]*$ ]] || { echo 'Invalid search index name.' >&2; exit 1; }
[[ "$alias_name" != "${ES_INDEX:-canvas}" ]] || { echo 'Search and snapshot indexes must differ.' >&2; exit 1; }
physical="${alias_name}-v1"
request() { es_curl_authenticated elastic "$ELASTIC_PASSWORD" --cacert "${ES_CA_CERT:?Configure the public ES CA}" "$@"; }
status=$(request -sS -o /dev/null -w '%{http_code}' "$endpoint/$alias_name")
if [[ "$status" == 404 ]]; then
    status=$(request -sS -o /dev/null -w '%{http_code}' "$endpoint/$physical")
    if [[ "$status" == 404 ]]; then
        request --fail --silent --show-error -X PUT -H 'Content-Type: application/json' \
            --data-binary "@$ROOT/search/index.json" "$endpoint/$physical" >/dev/null
    elif [[ "$status" != 200 ]]; then echo 'Search index preflight failed.' >&2; exit 1; fi
    payload=$(ALIAS_NAME="$alias_name" PHYSICAL="$physical" python3 - <<'PY'
import json,os
print(json.dumps({'actions':[{'add':{'index':os.environ['PHYSICAL'],'alias':os.environ['ALIAS_NAME'],'is_write_index':True}}]}))
PY
)
    request --fail --silent --show-error -X POST -H 'Content-Type: application/json' --data-binary "$payload" "$endpoint/_aliases" >/dev/null
elif [[ "$status" != 200 ]]; then echo 'Search alias preflight failed.' >&2; exit 1; fi
# Reject incompatible projection schemas without touching authoritative documents.
request --fail --silent --show-error "$endpoint/$alias_name/_mapping" | python3 -c '
import json,sys
mappings=json.load(sys.stdin)
for definition in mappings.values():
    mapping=definition.get("mappings", {})
    meta=mapping.get("_meta", {})
    vector=mapping.get("properties", {}).get("embedding", {})
    if meta.get("schema_version") != 1 or vector.get("dims") != 384 or vector.get("type") != "dense_vector":
        sys.exit("Incompatible search projection schema; create and migrate a new projection version.")
if not mappings: sys.exit("Missing search projection mapping.")
'
bash "$ROOT/sync-elasticsearch-users.sh"
echo 'Korean search projection initialized; original canvas documents preserved.'
