#!/bin/bash
# ==============================================================================
# Agora Elasticsearch Database & User Initialization Script
# .env 설정을 기반으로 인덱스 전용 역할 및 사용자 생성, 인덱스 매핑 구성 (샘플 데이터 제외)
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# .env 파일이 있으면 로드
if [ -f "$SCRIPT_DIR/.env" ]; then
  export $(grep -v '^#' "$SCRIPT_DIR/.env" | xargs)
elif [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

ES_RAW_IP="${ES_EXTERNAL_IP:-127.0.0.1}"
if [ "$ES_RAW_IP" = "0.0.0.0" ]; then
  ES_CONNECT_IP="127.0.0.1"
else
  ES_CONNECT_IP="$ES_RAW_IP"
fi
ES_PORT="${ES_EXTERNAL_PORT:-${ES_PORT:-9200}}"
ES_SCHEME="${ES_SCHEME:-http}"
if [ "$ES_SCHEME" != "http" ] && [ "$ES_SCHEME" != "https" ]; then
  echo "[ERROR] ES_SCHEME must be http or https." >&2
  exit 1
fi
ES_HOST="${ES_SCHEME}://${ES_CONNECT_IP}:${ES_PORT}"
ES_CURL_ARGS=()
if [ -n "${ES_CA_CERT:-}" ]; then ES_CURL_ARGS+=(--cacert "$ES_CA_CERT"); fi
curl_es() { curl "${ES_CURL_ARGS[@]}" "$@"; }
ES_SUPER_USER="elastic"
: "${ELASTIC_PASSWORD:?ELASTIC_PASSWORD must be set in elasticsearch/.env}"
ES_SUPER_PASS="$ELASTIC_PASSWORD"
INDEX_NAME="${ES_INDEX:-canvas}"
ES_USER="${ES_USER_NAME:-agora_user}"
: "${ES_USER_PASSWORD:?ES_USER_PASSWORD must be set in elasticsearch/.env}"
ES_USER_PASS="$ES_USER_PASSWORD"
ES_ROLE="${ES_USER}_role"
LOG_INDEX="${ES_LOG_INDEX:-agora-logs}"
LOG_USER="${ES_LOG_USER_NAME:-agora_log_writer}"
: "${ES_LOG_USER_PASSWORD:?ES_LOG_USER_PASSWORD must be set in elasticsearch/.env}"
LOG_USER_PASS="$ES_LOG_USER_PASSWORD"
LOG_ROLE="${LOG_USER}_write_role"
LOG_RETENTION_POLICY="${ES_LOG_RETENTION_POLICY:-agora-logs-retention}"
LOG_RETENTION_DAYS="${ES_LOG_RETENTION_DAYS:-90}"
SNAPSHOT_REPOSITORY="${ES_SNAPSHOT_REPOSITORY:-agora-filesystem}"

if [ "$LOG_INDEX" = "$INDEX_NAME" ]; then
  echo "[ERROR] ES_LOG_INDEX must be different from ES_INDEX ($INDEX_NAME)." >&2
  exit 1
fi
if [[ ! "$LOG_INDEX" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
  echo "[ERROR] ES_LOG_INDEX must be a lowercase Elasticsearch alias name." >&2
  exit 1
fi
if [ "$LOG_USER" = "$ES_USER" ] || [ "$LOG_USER" = "$ES_SUPER_USER" ]; then
  echo "[ERROR] ES_LOG_USER_NAME must be different from the canvas and superuser accounts." >&2
  exit 1
fi

echo "=== 1. Elasticsearch 역할 ($ES_ROLE) 생성 및 인덱스($INDEX_NAME) 권한 부여 ==="

curl_es -s -f -u "$ES_SUPER_USER:$ES_SUPER_PASS" -X PUT "$ES_HOST/_security/role/$ES_ROLE" \
     -H 'Content-Type: application/json' \
     -d "{
  \"cluster\": [],
  \"indices\": [
    {
      \"names\": [ \"$INDEX_NAME\" ],
      \"privileges\": [ \"read\", \"write\", \"view_index_metadata\" ]
    }
  ]
}"
echo -e "\n[OK] 역할($ES_ROLE) 생성 완료"

echo -e "\n=== 2. Elasticsearch 전용 사용자 계정 ($ES_USER) 생성 ==="

curl_es -s -f -u "$ES_SUPER_USER:$ES_SUPER_PASS" -X POST "$ES_HOST/_security/user/$ES_USER" \
     -H 'Content-Type: application/json' \
     -d "{
  \"password\": \"$ES_USER_PASS\",
  \"roles\": [ \"$ES_ROLE\" ],
  \"full_name\": \"Agora Index Owner User\"
}"
echo -e "\n[OK] 사용자($ES_USER) 생성 완료"

echo -e "\n=== 3. Elasticsearch 인덱스 ($INDEX_NAME) 매핑 생성 ==="

# 인덱스가 이미 존재하는지 확인 후 없을 때만 생성 (기존 문서가 없을 경우 최신 템플릿 적용을 위해 재생성)
INDEX_EXISTS=$(curl_es -s -o /dev/null -w "%{http_code}" -u "$ES_SUPER_USER:$ES_SUPER_PASS" "$ES_HOST/$INDEX_NAME")
if [ "$INDEX_EXISTS" = "200" ]; then
  DOC_COUNT=$(curl_es -s -u "$ES_SUPER_USER:$ES_SUPER_PASS" "$ES_HOST/$INDEX_NAME/_count" | grep -o '"count":[0-9]*' | cut -d':' -f2 || echo "0")
  if [ "$DOC_COUNT" = "0" ]; then
    echo "인덱스($INDEX_NAME)에 저장된 데이터가 없습니다(count: 0). 최신 스키마 템플릿 적용을 위해 재생성합니다..."
    curl_es -s -f -u "$ES_SUPER_USER:$ES_SUPER_PASS" -X DELETE "$ES_HOST/$INDEX_NAME" > /dev/null
    INDEX_EXISTS="404"
  else
    echo "인덱스($INDEX_NAME)가 이미 존재하며 기존 문서가 있습니다. 최신 필드 매핑을 동기화합니다..."
    curl_es -s -f -u "$ES_SUPER_USER:$ES_SUPER_PASS" -X PUT "$ES_HOST/$INDEX_NAME/_mapping" \
         -H 'Content-Type: application/json' \
         -d '{
      "properties": {
        "admin-user-id": {
          "type": "long"
        },
        "description": {
          "type": "text"
        },
        "canvas-password-hash": {
          "type": "keyword"
        },
        "people": {
          "type": "long"
        }
      }
    }'
    echo -e "\n[OK] 인덱스($INDEX_NAME) 매핑 동기화 완료"
  fi
fi

if [ "$INDEX_EXISTS" != "200" ]; then
  curl_es -s -f -u "$ES_SUPER_USER:$ES_SUPER_PASS" -X PUT "$ES_HOST/$INDEX_NAME" \
       -H 'Content-Type: application/json' \
       -d '{
    "settings": {
      "number_of_shards": 1,
      "number_of_replicas": 0
    },
    "mappings": {
      "dynamic_templates": [
        {
          "inner_group_uids": {
            "path_match": "inner-group.*",
            "mapping": {
              "type": "long"
            }
          }
        },
        {
          "item_id": {
            "path_match": "items.*.item-id",
            "mapping": {
              "type": "long"
            }
          }
        },
        {
          "item_type": {
            "path_match": "items.*.type",
            "mapping": {
              "type": "integer"
            }
          }
        },
        {
          "item_pos": {
            "path_match": "items.*.pos",
            "mapping": {
              "type": "float"
            }
          }
        },
        {
          "item_permission": {
            "path_match": "items.*.permission",
            "mapping": {
              "type": "keyword"
            }
          }
        }
      ],
      "properties": {
        "canvas-name": {
          "type": "text",
          "fields": {
            "keyword": {
              "type": "keyword",
              "ignore_above": 256
            }
          }
        },
        "canvas-id": {
          "type": "long"
        },
        "admin-user-id": {
          "type": "long"
        },
        "description": {
          "type": "text"
        },
        "canvas-password-hash": {
          "type": "keyword"
        },
        "people": {
          "type": "long"
        },
        "inner-group": {
          "type": "object"
        },
        "items": {
          "type": "object"
        },
        "init-group": {
          "type": "keyword"
        }
      }
    }
  }'
  echo -e "\n[OK] 인덱스($INDEX_NAME) 매핑 생성 완료 (초기 데이터 미삽입)"
fi

echo -e "\n=== 4. 로그 전용 역할($LOG_ROLE) 생성 ==="
curl_es -s -f -u "$ES_SUPER_USER:$ES_SUPER_PASS" -X PUT "$ES_HOST/_security/role/$LOG_ROLE" \
     -H 'Content-Type: application/json' \
     -d "{
  \"cluster\": [],
  \"indices\": [
    {
      \"names\": [ \"$LOG_INDEX\", \"$LOG_INDEX-*\" ],
      \"privileges\": [ \"auto_configure\", \"create_doc\" ]
    }
  ]
}"
echo -e "\n[OK] 역할($LOG_ROLE)은 로그 인덱스($LOG_INDEX)에 문서 추가 권한만 가집니다"

echo -e "\n=== 5. 로그 전용 사용자($LOG_USER) 생성 ==="
curl_es -s -f -u "$ES_SUPER_USER:$ES_SUPER_PASS" -X POST "$ES_HOST/_security/user/$LOG_USER" \
     -H 'Content-Type: application/json' \
     -d "{
  \"password\": \"$LOG_USER_PASS\",
  \"roles\": [ \"$LOG_ROLE\" ],
  \"full_name\": \"Agora Backend Log Writer\"
}"
echo -e "\n[OK] 로그 사용자($LOG_USER) 생성 완료"

echo -e "\n=== 6. 로그 인덱스 ($LOG_INDEX)와 보존 정책 준비 ==="
curl_es -s -f -u "$ES_SUPER_USER:$ES_SUPER_PASS" -X PUT "$ES_HOST/_ilm/policy/$LOG_RETENTION_POLICY" \
     -H 'Content-Type: application/json' --data-binary @- <<EOF
{"policy":{"phases":{"hot":{"actions":{"rollover":{"max_age":"1d","max_primary_shard_size":"10gb"}}},"delete":{"min_age":"${LOG_RETENTION_DAYS}d","actions":{"delete":{}}}}}}
EOF
curl_es -s -f -u "$ES_SUPER_USER:$ES_SUPER_PASS" -X PUT "$ES_HOST/_index_template/${LOG_INDEX}-template" \
     -H 'Content-Type: application/json' --data-binary @- <<EOF
{"index_patterns":["${LOG_INDEX}-*"],"priority":500,"template":{"settings":{"number_of_shards":1,"number_of_replicas":0,"index.lifecycle.name":"${LOG_RETENTION_POLICY}","index.lifecycle.rollover_alias":"${LOG_INDEX}"}}}
EOF

LOG_ALIAS_STATUS=$(curl_es -s -o /dev/null -w "%{http_code}" -u "$ES_SUPER_USER:$ES_SUPER_PASS" "$ES_HOST/_alias/$LOG_INDEX")
if [ "$LOG_ALIAS_STATUS" = "404" ]; then
  LEGACY_INDEX_STATUS=$(curl_es -s -o /dev/null -w "%{http_code}" -u "$ES_SUPER_USER:$ES_SUPER_PASS" "$ES_HOST/$LOG_INDEX")
  if [ "$LEGACY_INDEX_STATUS" = "200" ]; then
    echo "[ERROR] $LOG_INDEX is a concrete index. Back it up and run elasticsearch/migrate-log-index-to-ilm.sh while BE log writers are stopped." >&2
    exit 1
  fi
  curl_es -s -f -u "$ES_SUPER_USER:$ES_SUPER_PASS" -X PUT "$ES_HOST/${LOG_INDEX}-000001" \
       -H 'Content-Type: application/json' --data-binary @- <<EOF
{"settings":{"index.lifecycle.name":"${LOG_RETENTION_POLICY}","index.lifecycle.rollover_alias":"${LOG_INDEX}"},"aliases":{"${LOG_INDEX}":{"is_write_index":true}}}
EOF
  echo -e "\n[OK] 로그 쓰기 alias($LOG_INDEX)와 ILM 인덱스 생성 완료 (보존 ${LOG_RETENTION_DAYS}일)"
elif [ "$LOG_ALIAS_STATUS" = "200" ]; then
  echo "로그 쓰기 alias($LOG_INDEX)가 이미 존재합니다."
else
  echo "[ERROR] Elasticsearch alias 조회 실패 (HTTP $LOG_ALIAS_STATUS)." >&2
  exit 1
fi

echo -e "\n=== 7. 스냅샷 저장소와 일일 백업 보존 정책 구성 ==="
curl_es -s -f -u "$ES_SUPER_USER:$ES_SUPER_PASS" -X PUT "$ES_HOST/_snapshot/$SNAPSHOT_REPOSITORY" \
     -H 'Content-Type: application/json' -d '{"type":"fs","settings":{"location":"/usr/share/elasticsearch/snapshots","compress":true}}'
curl_es -s -f -u "$ES_SUPER_USER:$ES_SUPER_PASS" -X PUT "$ES_HOST/_slm/policy/agora-daily" \
     -H 'Content-Type: application/json' --data-binary @- <<EOF
{"schedule":"0 30 2 * * ?","name":"<agora-snapshot-{now/d}>","repository":"${SNAPSHOT_REPOSITORY}","config":{"indices":["${INDEX_NAME}","${LOG_INDEX}-*"],"include_global_state":false,"ignore_unavailable":true},"retention":{"expire_after":"35d","min_count":7,"max_count":35}}
EOF
echo "[OK] 매일 UTC 02:30 snapshot, 최대 35개/35일 보존 정책 구성 완료."

echo -e "\n=== 8. 신규 사용자($ES_USER) 인증 및 인덱스($INDEX_NAME) 메타데이터 접근 검증 ==="
curl_es -s -f -u "$ES_USER:$ES_USER_PASS" -X GET "$ES_HOST/$INDEX_NAME?pretty" | head -n 15
echo ""

echo -e "\n[SUCCESS] 캔버스 인덱스($INDEX_NAME)와 로그 인덱스($LOG_INDEX), 각 전용 사용자의 초기화가 완료되었습니다."
