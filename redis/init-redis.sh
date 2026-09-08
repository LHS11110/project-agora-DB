#!/bin/bash
# Redis Stack (RedisJSON + RediSearch) 인덱스 생성 및 샘플 데이터 등록 스크립트 (보안 적용)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# .env 파일이 있으면 로드
if [ -f "$SCRIPT_DIR/.env" ]; then
  export $(grep -v '^#' "$SCRIPT_DIR/.env" | xargs)
elif [ -f .env ]; then
  export $(grep -v '^#' .env | xargs)
fi

REDIS_HOST="127.0.0.1"
REDIS_PORT="${REDIS_PORT:-6379}"
REDIS_PASS="${REDIS_PASSWORD:-AgoraRedisSecret@Passw0rd!2026}"

# 로컬 redis-cli가 있으면 로컬 사용, 없으면 docker exec fallback 사용
if command -v redis-cli &> /dev/null; then
  REDIS_CMD="redis-cli -h $REDIS_HOST -p $REDIS_PORT -a $REDIS_PASS"
else
  REDIS_CMD="docker exec -i agora-redis-stack redis-cli -a $REDIS_PASS"
fi

echo "=== 1. Redis Stack RediSearch 인덱스 (idx:canvas) 생성 ==="
$REDIS_CMD FT.CREATE idx:canvas ON JSON PREFIX 1 "canvas:" SCHEMA \
    '$["canvas-name"]' AS canvas_name TEXT SORTABLE \
    '$["canvas-id"]' AS canvas_id NUMERIC SORTABLE \
    '$.admin' AS admin NUMERIC \
    '$.peoples[*]' AS peoples NUMERIC \
    '$["init-group"]' AS init_group TAG

echo -e "\n=== 2. RedisJSON 샘플 캔버스 데이터 저장 (Key: canvas:1) ==="
$REDIS_CMD JSON.SET canvas:1 $ '{
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
      "data1": "sample data",
      "permission": {
        "admin-group": 7,
        "group-name1": 5,
        "group-name2": 1
      }
    }
  },
  "init-group": "init-group-name"
}'

echo -e "\n=== 3. 저장된 JSON 데이터 확인 (JSON.GET) ==="
$REDIS_CMD JSON.GET canvas:1

echo -e "\n=== 4. RediSearch 검색 쿼리 테스트 (FT.SEARCH) ==="
$REDIS_CMD FT.SEARCH idx:canvas "@admin:[1000 1000]"
