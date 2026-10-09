#!/usr/bin/env bash
# Reconcile Elasticsearch application accounts with elasticsearch/.env.
# Safe to run during a routine backend startup; it does not alter canvas documents.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/curl-auth.sh"

if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set -a
  # The repository .env uses shell-compatible KEY=value entries.
  source "$SCRIPT_DIR/.env"
  set +a
else
  echo "[ERROR] Missing $SCRIPT_DIR/.env" >&2
  exit 1
fi

: "${ELASTIC_PASSWORD:?ELASTIC_PASSWORD must be set in elasticsearch/.env}"
: "${ES_USER_PASSWORD:?ES_USER_PASSWORD must be set in elasticsearch/.env}"
: "${ES_LOG_USER_PASSWORD:?ES_LOG_USER_PASSWORD must be set in elasticsearch/.env}"

ES_EXTERNAL_IP="${ES_EXTERNAL_IP:-127.0.0.1}"
if [[ "$ES_EXTERNAL_IP" == "0.0.0.0" ]]; then
  ES_CONNECT_IP="127.0.0.1"
else
  ES_CONNECT_IP="$ES_EXTERNAL_IP"
fi
ES_CONNECT_PORT="${ES_EXTERNAL_PORT:-${ES_PORT:-9200}}"
ES_SCHEME="${ES_SCHEME:-https}"
if [[ "$ES_SCHEME" != "https" ]]; then
  echo "[ERROR] ES_SCHEME must be https." >&2
  exit 1
fi
ES_HOST="${ES_SCHEME}://${ES_CONNECT_IP}:${ES_CONNECT_PORT}"
ES_CURL_ARGS=()
if [[ -n "${ES_CA_CERT:-}" ]]; then
  ES_CURL_ARGS+=(--cacert "$ES_CA_CERT")
fi

curl_es() {
  local credentials
  if [[ "${1:-}" == "-u" ]]; then
    credentials="${2:?Elasticsearch credentials are required}"
    shift 2
  else
    credentials="elastic:$ELASTIC_PASSWORD"
  fi
  es_curl_authenticated "${credentials%%:*}" "${credentials#*:}" ${ES_CURL_ARGS[@]+"${ES_CURL_ARGS[@]}"} "$@"
}

ES_INDEX="${ES_INDEX:-canvas}"
ES_USER="${ES_USER_NAME:-agora_user}"
ES_LOG_INDEX="${ES_LOG_INDEX:-agora-logs}"
ES_LOG_USER="${ES_LOG_USER_NAME:-agora_log_writer}"
ES_ROLE="${ES_USER}_role"
ES_LOG_ROLE="${ES_LOG_USER}_write_role"

if [[ "$ES_USER" == "elastic" || "$ES_LOG_USER" == "elastic" || "$ES_USER" == "$ES_LOG_USER" ]]; then
  echo "[ERROR] Elasticsearch application and log writer accounts must be distinct from each other and elastic." >&2
  exit 1
fi

curl_es -s -f -u "elastic:$ELASTIC_PASSWORD" "$ES_HOST/_security/_authenticate" >/dev/null

canvas_role_payload="$(ES_INDEX="$ES_INDEX" python3 - <<'PY'
import json
import os

print(json.dumps({
    "cluster": [],
    "indices": [{
        "names": [os.environ["ES_INDEX"]],
        "privileges": ["read", "write", "view_index_metadata"],
    }],
}))
PY
)"
canvas_user_payload="$(ES_USER_PASSWORD="$ES_USER_PASSWORD" ES_ROLE="$ES_ROLE" python3 - <<'PY'
import json
import os

print(json.dumps({
    "password": os.environ["ES_USER_PASSWORD"],
    "roles": [os.environ["ES_ROLE"]],
    "full_name": "Agora Index Owner User",
}))
PY
)"
log_role_payload="$(ES_LOG_INDEX="$ES_LOG_INDEX" python3 - <<'PY'
import json
import os

index = os.environ["ES_LOG_INDEX"]
print(json.dumps({
    "cluster": [],
    "indices": [{
        "names": [index, f"{index}-*"],
        "privileges": ["auto_configure", "create_doc"],
    }],
}))
PY
)"
log_user_payload="$(ES_LOG_USER_PASSWORD="$ES_LOG_USER_PASSWORD" ES_LOG_ROLE="$ES_LOG_ROLE" python3 - <<'PY'
import json
import os

print(json.dumps({
    "password": os.environ["ES_LOG_USER_PASSWORD"],
    "roles": [os.environ["ES_LOG_ROLE"]],
    "full_name": "Agora Backend Log Writer",
}))
PY
)"

printf '%s' "$canvas_role_payload" | curl_es -s -f -u "elastic:$ELASTIC_PASSWORD" \
  -X PUT "$ES_HOST/_security/role/$ES_ROLE" -H 'Content-Type: application/json' --data-binary @- >/dev/null
printf '%s' "$canvas_user_payload" | curl_es -s -f -u "elastic:$ELASTIC_PASSWORD" \
  -X PUT "$ES_HOST/_security/user/$ES_USER" -H 'Content-Type: application/json' --data-binary @- >/dev/null
printf '%s' "$log_role_payload" | curl_es -s -f -u "elastic:$ELASTIC_PASSWORD" \
  -X PUT "$ES_HOST/_security/role/$ES_LOG_ROLE" -H 'Content-Type: application/json' --data-binary @- >/dev/null
printf '%s' "$log_user_payload" | curl_es -s -f -u "elastic:$ELASTIC_PASSWORD" \
  -X PUT "$ES_HOST/_security/user/$ES_LOG_USER" -H 'Content-Type: application/json' --data-binary @- >/dev/null

# Confirm the canvas account can reach the configured index without reading documents.
curl_es -s -f -u "$ES_USER:$ES_USER_PASSWORD" "$ES_HOST/$ES_INDEX/_count" >/dev/null
# Authenticate the dedicated log writer too; cluster health only checks elastic.
curl_es -s -f -u "$ES_LOG_USER:$ES_LOG_USER_PASSWORD" "$ES_HOST/_security/_authenticate" >/dev/null
echo "[OK] Elasticsearch canvas and log writer accounts match elasticsearch/.env."
