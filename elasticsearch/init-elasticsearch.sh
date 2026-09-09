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
ES_HOST="http://${ES_CONNECT_IP}:${ES_PORT}"
ES_SUPER_USER="elastic"
ES_SUPER_PASS="${ELASTIC_PASSWORD:-AgoraElasticSecret@Passw0rd!2026}"
INDEX_NAME="${ES_INDEX:-canvas}"
ES_USER="${ES_USER_NAME:-agora_user}"
ES_USER_PASS="${ES_USER_PASSWORD:-AgoraUserSecret@Passw0rd!2026}"
ES_ROLE="${ES_USER}_role"

echo "=== 1. Elasticsearch 역할 ($ES_ROLE) 생성 및 인덱스($INDEX_NAME) 권한 부여 ==="

curl -s -f -u "$ES_SUPER_USER:$ES_SUPER_PASS" -X PUT "$ES_HOST/_security/role/$ES_ROLE" \
     -H 'Content-Type: application/json' \
     -d "{
  \"cluster\": [\"monitor\"],
  \"indices\": [
    {
      \"names\": [ \"$INDEX_NAME\" ],
      \"privileges\": [ \"all\" ]
    }
  ]
}"
echo -e "\n[OK] 역할($ES_ROLE) 생성 완료"

echo -e "\n=== 2. Elasticsearch 전용 사용자 계정 ($ES_USER) 생성 ==="

curl -s -f -u "$ES_SUPER_USER:$ES_SUPER_PASS" -X POST "$ES_HOST/_security/user/$ES_USER" \
     -H 'Content-Type: application/json' \
     -d "{
  \"password\": \"$ES_USER_PASS\",
  \"roles\": [ \"$ES_ROLE\" ],
  \"full_name\": \"Agora Index Owner User\"
}"
echo -e "\n[OK] 사용자($ES_USER) 생성 완료"

echo -e "\n=== 3. Elasticsearch 인덱스 ($INDEX_NAME) 매핑 생성 ==="

# 인덱스가 이미 존재하는지 확인 후 없을 때만 생성
INDEX_EXISTS=$(curl -s -o /dev/null -w "%{http_code}" -u "$ES_SUPER_USER:$ES_SUPER_PASS" "$ES_HOST/$INDEX_NAME")
if [ "$INDEX_EXISTS" = "200" ]; then
  echo "인덱스($INDEX_NAME)가 이미 존재합니다. 최신 필드 매핑(canvas-password)을 동기화합니다..."
  curl -s -f -u "$ES_SUPER_USER:$ES_SUPER_PASS" -X PUT "$ES_HOST/$INDEX_NAME/_mapping" \
       -H 'Content-Type: application/json' \
       -d '{
    "properties": {
      "canvas-password": {
        "type": "keyword"
      }
    }
  }'
  echo -e "\n[OK] 인덱스($INDEX_NAME) 매핑 동기화 완료"
else
  curl -s -f -u "$ES_SUPER_USER:$ES_SUPER_PASS" -X PUT "$ES_HOST/$INDEX_NAME" \
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
            "path_match": "items.*.permission.*",
            "mapping": {
              "type": "byte"
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
        "admin": {
          "type": "long"
        },
        "canvas-password": {
          "type": "keyword"
        },
        "peoples": {
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

echo -e "\n=== 4. 신규 사용자($ES_USER) 인증 및 인덱스($INDEX_NAME) 메타데이터 접근 검증 ==="
curl -s -f -u "$ES_USER:$ES_USER_PASS" -X GET "$ES_HOST/$INDEX_NAME?pretty" | head -n 15
echo ""

echo -e "\n[SUCCESS] Elasticsearch 인덱스($INDEX_NAME) 및 소유 사용자($ES_USER) 초기화가 완료되었습니다."
