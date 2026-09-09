# project-agora-DB

아고라(Agora) 프로젝트의 데이터베이스 인프라 구축, 스키마/인덱스 설정 및 검증 가이드입니다.

- **MS SQL Server**: 회원 정보, 서버 인스턴스 정보 및 캔버스 캐시 메타데이터 영구 관리
- **Elasticsearch**: 캔버스 및 캔버스 내 아이템 검색/저장용 분산 검색 엔진
- **Redis Stack**: RedisJSON 및 RediSearch를 이용한 인메모리 캔버스 캐시, 실시간 검색 및 RedisInsight 모니터링

---

## 📁 디렉터리 구조

각 서비스별로 설정 파일(`.env`, 초기화 스크립트)과 `docker-compose.yml`이 분리되어 독립적으로 관리되며, 프로젝트 루트에서 일괄 실행할 수도 있습니다.

```
project-agora-DB/
├── docker-compose.yml              # 전체 서비스 일괄 실행 Compose (include 방식)
├── elasticsearch/                  # Elasticsearch 서비스 (8.15.0)
│   ├── docker-compose.yml
│   ├── .env.example
│   ├── .env
│   └── init-elasticsearch.sh      # 역할, 일반 사용자 생성 및 인덱스 매핑 설정
├── redis/                          # Redis Stack 서비스 (RedisJSON + RediSearch)
│   ├── docker-compose.yml
│   ├── .env.example
│   ├── .env
│   ├── init-redis.sh               # ACL 사용자, RediSearch 인덱스 생성 & MS SQL 자동 등록
│   └── register-to-mssql.sh        # Redis 접속 정보를 MS SQL에 단독 등록
├── mssql/                          # MS SQL Server 2022 서비스
│   ├── docker-compose.yml
│   ├── .env.example
│   ├── .env
│   ├── init-mssql.sh               # DB, 계정(dbo) 생성 및 테이블 스키마 초기화
│   └── init-mssql.sql              # DDL 및 인덱스/제약조건 정의 SQL
├── tests/                          # 일반 사용자 권한 및 CRUD 통합 테스트
│   ├── test-storages.sh            # Bash 기반 29개 통합 테스트 스위트
│   └── test_storages.py            # Python 기반 29개 통합 테스트 스위트
├── elasticsearch_and_redis_stack.txt # 캔버스 JSON 데이터 모델 명세
└── mssql.txt                       # MS SQL 테이블 요구사항 명세
```

---

## ⚙️ 사전 환경 설정 (.env)

각 서비스 디렉터리의 `.env.example`을 복사하여 `.env` 파일을 생성하고 필요한 설정을 조정합니다.

```bash
cp elasticsearch/.env.example elasticsearch/.env
cp redis/.env.example redis/.env
cp mssql/.env.example mssql/.env
```

### 📊 서비스별 기본 포트 및 환경 변수

| 서비스 | 기본 컨테이너 내부 포트 | 호스트 노출 포트 (기본값) | 호스트 바인딩 IP 설정 | MS SQL 등록 / 외부 접속 IP | 주요 계정 및 기본 DB / 인덱스 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **MS SQL** | `1433` | `1433` | `MSSQL_EXTERNAL_IP` (`0.0.0.0`) | - | `sa` (관리자)<br>`agora_user` (일반 사용자, `dbo` 권한)<br>DB: `agora_db` |
| **Elasticsearch** | `9200` | `9200` | `ES_EXTERNAL_IP` (`127.0.0.1`) | - | `elastic` (슈퍼유저)<br>`agora_user` (인덱스 전용 계정)<br>Index: `canvas` |
| **Redis Stack** | `6379`<br>`8001` (Insight) | `6379`<br>`8001` | `REDIS_BIND_IP` (`0.0.0.0`) | `REDIS_EXTERNAL_IP` (`127.0.0.1`) | `default` (관리자 암호 보호)<br>`agora_user` (ACL 계정, `canvas:*` 권한)<br>Index: `idx:canvas` |

> [!TIP]
> - **바인딩 IP vs MS SQL 등록 IP 분리**: AWS EC2 등 클라우드/NAT 환경에서는 호스트 OS에 공인 IP가 직접 바인딩되지 않아 공인 IP로 포트 바인딩 시 `cannot assign requested address` 에러가 발생합니다.
> - 따라서 Redis의 Docker 호스트 포트 수신 바인딩은 `REDIS_BIND_IP=0.0.0.0`으로 설정하고, MS SQL(`redis_server` 테이블)에 등록하여 외부 클라이언트가 찾아갈 공인 IP는 `REDIS_EXTERNAL_IP`로 명확하게 역할을 나누어 설정합니다.

---

## 🚀 1. 컨테이너 실행 방법

### 방법 A: 전체 서비스 일괄 실행 (프로젝트 루트)

프로젝트 루트의 `docker-compose.yml`은 Docker Compose `include` 기능을 사용하여 세 서비스를 일괄 관리합니다.
```bash
docker compose up -d
```

### 방법 B: 각 서비스별 개별 실행

원하는 서비스 디렉터리로 이동하여 단독으로 실행할 수 있습니다.

```bash
# 1. Elasticsearch 실행
cd elasticsearch && docker compose up -d && cd ..

# 2. Redis Stack 실행
cd redis && docker compose up -d && cd ..

# 3. MS SQL 실행
cd mssql && docker compose up -d && cd ..
```

컨테이너 상태 확인:
```bash
docker compose ps
```

---

## 🛠 2. 스키마 및 사용자 초기화

컨테이너가 정상 구동된 후, 각 스토리지의 사용자 계정 생성, 권한 부여, 스키마/인덱스 생성을 진행합니다.

### (1) MS SQL 사용자 생성, 데이터베이스 소유권 부여 및 테이블 생성
- 일반 사용자(`agora_user`)에게 `agora_db`의 `dbo` 소유권을 부여하여 불필요한 sa 권한 노출 없이 운영할 수 있도록 구성합니다.
- 테이블명(`users`, `redis_server`, `canvas_cache`, `python_server`)은 `.env`에서 변경할 수 있습니다.

```bash
./mssql/init-mssql.sh
```

*(또는 Docker 명령어로 직접 실행)*
```bash
docker exec -i agora-mssql /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U sa -P 'AgoraStrong@Passw0rd!2026' -C -I \
  -v DB_NAME='agora_db' -v DB_USER='agora_user' -v DB_PASSWORD='AgoraUserSecret@Passw0rd!2026' \
     TABLE_USERS='users' TABLE_REDIS_SERVER='redis_server' TABLE_CANVAS_CACHE='canvas_cache' \
     TABLE_PYTHON_SERVER='python_server' \
  < mssql/init-mssql.sql
```

### (2) Elasticsearch 사용자 생성, 역할 부여 및 인덱스 매핑 생성
- 일반 사용자 전용 역할(`agora_user_role`)을 생성하고 지정된 인덱스(`canvas`)에 대해 읽기/쓰기/인덱스 관리 권한을 부여합니다.
- 캔버스 문서 및 내부 아이템 구조에 최적화된 필드 매핑(Mapping)을 구성합니다.

```bash
./elasticsearch/init-elasticsearch.sh
```

### (3) Redis Stack ACL 사용자 생성, RediSearch 인덱스 생성 및 MS SQL 자동 등록
- Redis ACL을 통해 일반 사용자(`agora_user`)에게 `canvas:*` 키 네임스페이스 및 RedisJSON/RediSearch 실행 권한만 최소 부여합니다.
- JSON 타입의 `idx:canvas` RediSearch 인덱스를 생성합니다.
- 초기화 완료 시 `redis/.env`에 지정된 외부 접속 IP(`REDIS_EXTERNAL_IP`)와 외부 포트(`REDIS_EXTERNAL_PORT`)를 MS SQL Server의 `redis_server` 테이블에 자동으로 등록합니다 (중복 등록 방지 처리 포함).

```bash
./redis/init-redis.sh
```

> [!NOTE]
> 만약 Redis의 외부 접속 정보(IP, Port)가 변경되어 MS SQL에 단독으로 재등록하고 싶다면 아래 스크립트를 단독 실행할 수 있습니다:
> ```bash
> ./redis/register-to-mssql.sh
> ```

---

## 📐 3. 데이터 모델 및 스키마 명세

### 1) MS SQL Server 스키마

#### `users` (회원 테이블)
- `user_id`: `INT IDENTITY(1,1)` (PK, 클러스터드 인덱스)
- `email`: `NVARCHAR(255) NOT NULL` (UNIQUE 넌클러스터드 인덱스 `UQ_Users_Email`)
- `password_hash`: `NVARCHAR(255) NULL`
- `nickname`: `NVARCHAR(100) NOT NULL`
- `role`: `NVARCHAR(50) NOT NULL DEFAULT 'ROLE_USER'`
- `status`: `NVARCHAR(20) NOT NULL DEFAULT 'ACTIVE'` (CHECK 제약 조건: `ACTIVE`, `SUSPENDED`, `WITHDRAWN`)
- `oauth_provider`: `NVARCHAR(50) NULL`
- `oauth_id`: `NVARCHAR(255) NULL`
- `last_login_at`: `DATETIME2 NULL`
- `password_changed_at`: `DATETIME2 NULL`
- `created_at`: `DATETIME2 NOT NULL DEFAULT SYSDATETIME()`
- `updated_at`: `DATETIME2 NOT NULL DEFAULT SYSDATETIME()`
- **인덱스**:
  - `IX_Users_OAuth` : `(oauth_provider, oauth_id)` (조건부 필터 인덱스: `WHERE oauth_provider IS NOT NULL`)
  - `IX_Users_Nickname` : `(nickname)` (넌클러스터드 인덱스)

#### `redis_server` (Redis 서버 인스턴스 관리)
- `redis_id`: `INT IDENTITY(1,1)` (PK)
- `redis_ip`: `VARCHAR(45) NOT NULL`
- `redis_port`: `VARCHAR(10) NOT NULL`
- `created_at`: `DATETIME2 NOT NULL DEFAULT SYSDATETIME()`

#### `canvas_cache` (캔버스 캐시 상태 확인)
- `canvas_id`: `INT` (PK)
- `canvas_name`: `NVARCHAR(255) NOT NULL` (공백 불가)
- `redis_ip`: `VARCHAR(45) NULL` (FK: `redis_server(redis_ip, redis_port)`)
- `redis_port`: `VARCHAR(10) NULL` (FK: `redis_server(redis_ip, redis_port)`)
- `server_ip`: `VARCHAR(45) NULL` (FK: `python_server(server_ip, server_port)`)
- `server_port`: `VARCHAR(10) NULL` (FK: `python_server(server_ip, server_port)`)
- `is_cached`: `BIT NOT NULL DEFAULT 0`
- `created_at`: `DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()`
- `updated_at`: `DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()`

#### `python_server` (Python 실시간 서버 인스턴스 관리)
- `server_id`: `INT IDENTITY(1,1)` (PK)
- `server_ip`: `VARCHAR(45) NOT NULL`
- `server_port`: `VARCHAR(10) NOT NULL`
- `created_at`: `DATETIME2 NOT NULL DEFAULT SYSDATETIME()`

---

### 2) Redis Stack & Elasticsearch 캔버스 데이터 모델

Redis는 `canvas:{canvas_id}` 키에 JSON 형식으로 저장하며, Elasticsearch는 `canvas` 인덱스에 동일 구조의 도큐먼트로 저장 및 검색됩니다.

```json
{
  "canvas-name": "Agora Shared Canvas",
  "canvas-id": 1001,
  "admin": 1,
  "peoples": [1, 2, 3, 4],
  "inner-group": {
    "group-name1": [1, 2],
    "group-name2": [3, 4],
    "init-group-name": [1, 2, 3, 4],
    "admin-group": [1]
  },
  "items": {
    "item-1": {
      "item-id": 1,
      "type": 10,
      "pos": [120.5, 340.0],
      "data1": "sample metadata",
      "permission": {
        "admin-group": 7,
        "group-name1": 5,
        "group-name2": 1
      }
    }
  },
  "init-group": "init-group-name"
}
```

---

## 🧪 4. 통합 검증 테스트 (29개 항목)

초기화 완료 후, 생성된 일반 사용자 계정(`agora_user`)으로 각 저장소의 연결, 권한 격리 및 CRUD/검색 동작을 자동화된 테스트 코드로 일괄 검증할 수 있습니다.
모든 테스트는 격리된 테스트 레코드를 생성하고 테스트 완료 후 **자동 롤백/클린업**합니다.

### 방법 A: Bash 테스트 스크립트 실행
별도 패키지 설치 없이 Docker 및 기본 curl/bash 도구로 검증합니다.
```bash
./tests/test-storages.sh
```

### 방법 B: Python 테스트 스크립트 실행
Python 3 표준 라이브러리(urllib, subprocess, json) 기반으로 작성되어 pip 설치 없이 즉시 실행 가능합니다.
```bash
python3 tests/test_storages.py
```

### 📋 테스트 검증 항목 (총 29개)

| 저장소 | 대상 계정 | 번호 | 검증 항목 | 상세 내용 |
| :--- | :--- | :---: | :--- | :--- |
| **MS SQL** | `agora_user` | 1 | 계정 인증 및 DB 소유권 | `agora_db`에 대한 `dbo` 소유권 확인 |
| | | 2 | 테이블 생성 확인 | `users`, `redis_server`, `canvas_cache`, `python_server` 존재 여부 |
| | | 3 | 회원 [Create] | `users` 테이블 테스트 회원 INSERT |
| | | 4 | 회원 [Read] | 회원 조회 및 `status = 'ACTIVE'` 확인 |
| | | 5 | 회원 [Update] | 회원 `status`를 `SUSPENDED`로 수정 확인 |
| | | 6 | 회원 [Delete] | 테스트 회원 데이터 삭제 (클린업) |
| | | 7 | 캐시/Redis [Create] | `redis_server` 및 `canvas_cache` (PK: 9999) INSERT |
| | | 8 | 캐시 [Read] | `canvas_cache` 조회 및 `is_cached = 0` 확인 |
| | | 9 | 캐시 [Update] | `canvas_cache`의 `is_cached`를 `1`로 수정 확인 |
| | | 10 | 캐시/Redis [Delete] | 캐시 및 Redis 서버 테스트 데이터 삭제 (클린업) |
| | | 11 | Python 서버 [Create] | `python_server` 테이블 테스트 서버 인스턴스 INSERT |
| | | 12 | Python 서버 [Read] | Python 서버 포트(8000) 조회 확인 |
| | | 13 | Python 서버 [Update] | Python 서버 포트(8000 -> 8080) 수정 확인 |
| | | 14 | Python 서버 [Delete] | Python 서버 테스트 데이터 삭제 (클린업) |
| **Elasticsearch** | `agora_user` | 15 | 계정 인증 및 역할 | Basic 인증 및 `agora_user_role` 역할 매핑 확인 |
| | | 16 | 인덱스 접근 권한 | `canvas` 인덱스 접근 및 클러스터 상태 확인 |
| | | 17 | 도큐먼트 [Create] | `canvas` 인덱스에 캔버스 JSON 도큐먼트 색인 |
| | | 18 | 도큐먼트 [Read] | Document ID 기반 단건 조회 확인 |
| | | 19 | 검색 쿼리 [Search] | `match` 쿼리를 통한 전문 검색 동작 확인 |
| | | 20 | 도큐먼트 [Update] | 도큐먼트 필드 갱신 및 버전 증가 확인 |
| | | 21 | 도큐먼트 [Delete] | 테스트 도큐먼트 삭제 (클린업) |
| **Redis Stack** | `agora_user` | 22 | ACL 인증 | `AUTH agora_user` 및 `PING -> PONG` 확인 |
| | | 23 | RediSearch 인덱스 | `FT.INFO idx:canvas` 인덱스 메타데이터 확인 |
| | | 24 | RedisJSON [Create] | `JSON.SET canvas:9999 $ <json>` 생성 확인 |
| | | 25 | RedisJSON [Read] | `JSON.GET canvas:9999` 데이터 조회 확인 |
| | | 26 | RediSearch [Search] | `FT.SEARCH idx:canvas` 전문 검색 쿼리 확인 |
| | | 27 | RedisJSON [Update] | `JSON.SET canvas:9999 $.admin 2000` 필드 수정 확인 |
| | | 28 | RedisJSON [Delete] | `DEL canvas:9999` 삭제 확인 (클린업) |
| | | 29 | 보안 격리 [Scope] | 허용되지 않은 키(`other:unauthorized`) 쓰기 시 `NOPERM` 차단 확인 |
