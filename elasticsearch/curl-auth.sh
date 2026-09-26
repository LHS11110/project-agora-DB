#!/usr/bin/env bash
# Send Elasticsearch HTTP Basic credentials to curl's stdin config, not argv.
es_curl_authenticated() {
  local username="${1:?Elasticsearch username is required}"
  local password="${2:?Elasticsearch password is required}"
  local credentials auth_config curl_status
  shift 2

  case "$username$password" in
    *$'\n'*|*$'\r'*)
      echo "Elasticsearch credentials may not contain line breaks." >&2
      return 2
      ;;
  esac

  credentials="$username:$password"
  credentials="${credentials//\\/\\\\}"
  credentials="${credentials//\"/\\\"}"
  auth_config="$(mktemp "${TMPDIR:-/tmp}/agora-es-curl.XXXXXX")"
  chmod 600 "$auth_config"
  printf 'user = "%s"\n' "$credentials" > "$auth_config"
  if curl --config "$auth_config" "$@"; then
    curl_status=0
  else
    curl_status=$?
  fi
  rm -f "$auth_config"
  return "$curl_status"
}
