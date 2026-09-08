# project-agora-DB

아고라(Agora) 프로젝트의 데이터베이스 인프라 구축 및 스키마/인덱스 설정 가이드입니다.

- **Elasticsearch**: 캔버스 및 아이템 검색/저장용 검색 엔진
- **Redis Stack**: RedisJSON 및 RediSearch를 이용한 인메모리 캔버스 캐시 및 실시간 조회
- **MS SQL**: 캔버스 캐시 상태 확인 및 영구 메타데이터 관리

---

## 📁 디렉터리 구조

각 서비스별로 설정 파일(`.env`, 초기화 스크립트)과 `docker-compose.yml`이 분리되어 독립적으로 관리됩니다.

```
project-agora-DB/
├── docker-compose.yml              # 전체 서비스 일괄 실행 Compose (include 사용)
├── elasticsearch/                  # Elasticsearch 서비스
│   ├── docker-compose.yml
│   ├── .env.example
│   ├── .env
│   └── init-elasticsearch.sh
├── redis/                          # Redis Stack 서비스
│   ├── docker-compose.yml
│   ├── .env.example
│   ├── .env
│   └── init-redis.sh
└── mssql/                          # MS SQL Server 서비스
    ├── docker-compose.yml
    ├── .env.example
    ├── .env
    └── init-mssql.sql
```

---

## 🚀 1. 컨테이너 실행 방법

### 방법 A: 전체 서비스 일괄 실행 (프로젝트 루트)

프로젝트 루트 디렉터리에서 다음 명령어를 실행합니다.
```bash
docker compose up -d
```

### 방법 B: 각 서비스별 개별 실행

원하는 서비스 디렉터리로 이동하여 단독으로 실행할 수 있습니다.

```bash
# 1. Elasticsearch 단독 실행
cd elasticsearch
docker compose up -d

# 2. Redis Stack 단독 실행
cd redis
docker compose up -d

# 3. MS SQL 단독 실행
cd mssql
docker compose up -d
```

---

## 📊 컨테이너 및 포트 구성

| 서비스 | 컨테이너 이름 | 포트 | 용도 |
| :--- | :--- | :--- | :--- |
| **Elasticsearch** | `agora-elasticsearch` | `127.0.0.1:9200` | REST API |
| **Redis Stack** | `agora-redis-stack` | `6379`, `8001` | Redis 서버 (`6379`) / RedisInsight 웹 UI (`8001`) |
| **MS SQL 2022** | `agora-mssql` | `127.0.0.1:1433` | SQL Server DB |

---

## ⚙️ 2. 데이터베이스 초기화 및 인덱스 생성

각 서비스 컨테이너가 실행된 후 아래의 초기화 작업을 수행합니다.

### (1) MS SQL 테이블 생성
```bash
docker exec -i agora-mssql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P 'AgoraStrong@Passw0rd!2026' -C < mssql/init-mssql.sql
```

### (2) Elasticsearch 인덱스 및 매핑 생성
```bash
./elasticsearch/init-elasticsearch.sh
```

### (3) Redis Stack 인덱스 생성 및 샘플 데이터 등록
```bash
# 컨테이너 내부 redis-cli를 통해 실행
docker exec -i agora-redis-stack redis-cli -a 'AgoraRedisSecret@Passw0rd!2026' < redis/init-redis.sh
```
*(또는 로컬에 redis-cli가 설치되어 있는 경우 `./redis/init-redis.sh` 직접 실행)*