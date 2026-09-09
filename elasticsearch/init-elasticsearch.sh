#!/bin/bash
# ==============================================================================
# Agora Elasticsearch Database & User Initialization Script
# .env 설정을 기반으로 인덱스 전용 역할 및 사용자 생성, 인덱스 매핑 구성 및 데이터 등록
# ==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# .env 파일이 있으면 로드
if [ -f "$SCRIPT_DIR/.env" ]; then
  export $(grep -v '^#' "$SCRIPT_DIR/.env" | xargs)
elif [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

ES_HOST="http://127.0.0.1:${ES_PORT:-9200}"
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
  echo "인덱스($INDEX_NAME)가 이미 존재합니다. 매핑 생성을 건너뜁니다."
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
  echo -e "\n[OK] 인덱스($INDEX_NAME) 생성 완료"
fi

CANVAS_NAME="Agora Architecture Canvas"
ENCODED_DOC_ID="${CANVAS_NAME// /%20}"

echo -e "\n=== 4. 샘플 캔버스 도큐먼트 등록 (ID: $CANVAS_NAME) ==="

curl -s -f -u "$ES_SUPER_USER:$ES_SUPER_PASS" -X PUT "$ES_HOST/$INDEX_NAME/_doc/$ENCODED_DOC_ID" \
     -H 'Content-Type: application/json' \
     -d '{
  "canvas-name": "Agora Architecture Canvas",
  "canvas-id": 1,
  "admin": 1000,
  "peoples": [1000, 1001, 1002, 1003],
  "inner-group": {
    "group-name1": [1001, 1002],
    "group-name2": [1003],
    "init-group-name": [1001, 1002, 1003],
    "admin-group": [1000]
  },
  "items": {
    "item-name1": {
      "type": 1,
      "pos": [120.5, 340.8],
      "data1": "memo text",
      "permission": {
        "admin-group": 7,
        "group-name1": 5,
        "group-name2": 1
      }
    }
  },
  "init-group": "init-group-name"
}'
echo -e "\n[OK] 도큐먼트 등록 완료"

echo -e "\n=== 5. 신규 사용자($ES_USER) 인증 및 인덱스($INDEX_NAME) 조회 권한 검증 ==="
curl -s -f -u "$ES_USER:$ES_USER_PASS" -X GET "$ES_HOST/$INDEX_NAME/_doc/$ENCODED_DOC_ID?pretty"
echo ""

echo -e "\n[SUCCESS] Elasticsearch 인덱스($INDEX_NAME) 및 소유 사용자($ES_USER) 초기화가 완료되었습니다."
