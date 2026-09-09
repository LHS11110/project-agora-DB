#!/bin/bash
# Elasticsearch 인덱스 생성 및 샘플 데이터 등록 스크립트 (운영 보안 설정 반영)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# .env 파일이 있으면 로드
if [ -f "$SCRIPT_DIR/.env" ]; then
  export $(grep -v '^#' "$SCRIPT_DIR/.env" | xargs)
elif [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

ES_HOST="http://localhost:${ES_PORT:-9200}"
ES_USER="elastic"
ES_PASS="${ELASTIC_PASSWORD:-AgoraElasticSecret@Passw0rd!2026}"
INDEX_NAME="canvas"

echo "=== 1. Elasticsearch 인덱스 ($INDEX_NAME) 매핑 생성 ==="

curl -u "$ES_USER:$ES_PASS" -X PUT "$ES_HOST/$INDEX_NAME" \
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

CANVAS_NAME="Agora Architecture Canvas"
ENCODED_DOC_ID="${CANVAS_NAME// /%20}"

echo -e "\n\n=== 2. 샘플 캔버스 도큐먼트 등록 (ID: $CANVAS_NAME) ==="

curl -u "$ES_USER:$ES_PASS" -X PUT "$ES_HOST/$INDEX_NAME/_doc/$ENCODED_DOC_ID" \
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

echo -e "\n\n=== 3. 등록된 도큐먼트 조회 (ID: $CANVAS_NAME) ==="
curl -u "$ES_USER:$ES_PASS" -X GET "$ES_HOST/$INDEX_NAME/_doc/$ENCODED_DOC_ID?pretty"
echo ""
