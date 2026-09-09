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
├── mssql/                          # MS SQL Server 서비스
│   ├── docker-compose.yml
│   ├── .env.example
│   ├── .env
│   ├── init-mssql.sh
│   └── init-mssql.sql
└── tests/                          # 일반 사용자 조회 통합 테스트
    ├── test-storages.sh
    └── test_storages.py
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

각 서비스 컨테이너가 실행된 후 아래의 초기화 작업을 수행합니다. 초기화 시 스키마와 인덱스, 전용 계정만 생성되며 **샘플 데이터는 삽입되지 않습니다.**

### (1) MS SQL 사용자 생성, 데이터베이스 소유권 부여 및 테이블 생성
테이블 이름(`MSSQL_TABLE_USERS`, `MSSQL_TABLE_REDIS_SERVER`, `MSSQL_TABLE_CANVAS_CACHE`)은 `.env`에서 변경할 수 있습니다.
```bash
./mssql/init-mssql.sh
```
*(또는 Docker 컨테이너 명령어로 직접 실행)*
```bash
docker exec -i agora-mssql /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U sa -P 'AgoraStrong@Passw0rd!2026' -C -I \
  -v DB_NAME='agora_db' -v DB_USER='agora_user' -v DB_PASSWORD='AgoraUserSecret@Passw0rd!2026' \
     TABLE_USERS='users' TABLE_REDIS_SERVER='redis_server' TABLE_CANVAS_CACHE='canvas_cache' \
  < mssql/init-mssql.sql
```

### (2) Elasticsearch 사용자 생성, 역할 부여 및 인덱스 매핑 생성
인덱스명(`ES_INDEX`)은 `.env`에서 변경할 수 있습니다.
```bash
./elasticsearch/init-elasticsearch.sh
```

### (3) Redis Stack ACL 사용자 생성 및 RediSearch 인덱스 생성
인덱스명(`REDIS_INDEX_NAME`)과 네임스페이스 프리픽스(`REDIS_KEY_PREFIX`)는 `.env`에서 변경할 수 있습니다.
```bash
./redis/init-redis.sh
```
*(로컬에 redis-cli가 없더라도 스크립트 내부에서 자동으로 Docker 컨테이너 명령어로 fallback 실행됩니다.)*

---

## 🧪 3. 사용자 권한 및 데이터 CRUD/검색 테스트

초기화 완료 후, 생성된 일반 사용자 계정(`agora_user`)으로 각 저장소의 연결, 권한 격리 및 CRUD/검색 동작을 자동화된 테스트 코드로 검증할 수 있습니다. 테스트는 임시 데이터를 생성 후 완료 시 자동 삭제(클린업)하여 저장소를 깨끗한 상태로 유지합니다.

### 방법 A: Bash 테스트 스크립트 실행
추가 패키지 설치 없이 Docker 및 기본 도구를 통해 25개 테스트 항목을 일괄 검증합니다.
```bash
./tests/test-storages.sh
```

### 방법 B: Python 테스트 스크립트 실행
표준 라이브러리 기반으로 작성되어 별도 pip 설치 없이 즉시 실행 가능합니다.
```bash
python3 tests/test_storages.py
```

### 📋 테스트 항목 요약 (총 25개 항목)
| 저장소 | 사용자 | 검증 항목 |
| :--- | :--- | :--- |
| **MS SQL** | `agora_user` | ① 사용자 인증 및 DB 소유권(`dbo`) 확인<br>② 환경변수 지정 테이블(`users`, `redis_server`, `canvas_cache`) 생성 여부 확인<br>③ 회원 테이블(`users`) 데이터 삽입 [Create]<br>④ 회원 테이블(`users`) 데이터 조회 [Read]<br>⑤ 회원 테이블(`users`) 데이터 수정 [Update]<br>⑥ 회원 테이블(`users`) 데이터 삭제 [Delete] (클린업)<br>⑦ 캐시 테이블(`canvas_cache`, `redis_server`) 데이터 삽입 [Create] (`canvas_id` PK)<br>⑧ 캐시 테이블 데이터 조회 [Read]<br>⑨ 캐시 테이블 데이터 수정 [Update]<br>⑩ 캐시 테이블 데이터 삭제 [Delete] (클린업 완료) |
| **Elasticsearch** | `agora_user` | ① Security 인증 및 `agora_user_role` 역할 확인<br>② 인덱스 존재 및 접근 권한 확인<br>③ 도큐먼트 삽입 [Create]<br>④ 도큐먼트 단건 조회 [Read]<br>⑤ 검색 쿼리 [Search]<br>⑥ 도큐먼트 수정 [Update]<br>⑦ 도큐먼트 삭제 [Delete] (클린업 완료) |
| **Redis Stack** | `agora_user` | ① Redis ACL 인증 (`PING` -> `PONG`)<br>② RediSearch 인덱스 정보 조회<br>③ RedisJSON 데이터 삽입 [Create]<br>④ RedisJSON 데이터 조회 [Read]<br>⑤ RediSearch 검색 쿼리 [Search]<br>⑥ RedisJSON 데이터 수정 [Update]<br>⑦ RedisJSON 데이터 삭제 [Delete] (클린업 완료)<br>⑧ 타 네임스페이스 키 접근 차단 [Scope Restriction] |