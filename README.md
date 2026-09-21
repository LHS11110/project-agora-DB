# project-agora-DB

아고라(Agora) 프로젝트의 데이터베이스 인프라 구축, 스키마/인덱스 설정 및 검증 가이드입니다.

- **MS SQL Server**: 회원 정보, 서버 인스턴스 정보 및 캔버스 메타데이터 영구 관리
- **Elasticsearch**: 캔버스 및 캔버스 내 아이템 검색/저장용 분산 검색 엔진
- **Redis Stack**: RedisJSON 및 RediSearch를 이용한 인메모리 캔버스 캐시, 실시간 검색 및 RedisInsight 모니터링

---

## 📁 디렉터리 구조

각 서비스별로 설정 파일(`.env`, 초기화 스크립트)과 `docker-compose.yml`이 분리되어 독립적으로 관리되며, 프로젝트 루트에서 일괄 실행할 수도 있습니다.

```
project-agora-DB/
├── docker-compose.yml              # 전체 서비스 일괄 실행 Compose (include 방식)
├── search-storages.sh              # 전체 저장소 데이터 통합 검색/조회 스크립트 (Bash)
├── search_storages.py              # 전체 저장소 데이터 통합 검색/조회 스크립트 (Python)
├── clean-storages.sh               # 저장소 데이터 일괄 삭제 스크립트 (Bash)
├── clean_storages.py               # 저장소 데이터 일괄 삭제 스크립트 (Python)
├── elasticsearch/                  # Elasticsearch 서비스 (8.15.0)
│   ├── docker-compose.yml
│   ├── .env.example
│   ├── .env
│   ├── init-elasticsearch.sh      # 역할, 일반 사용자 생성 및 인덱스 매핑 설정
│   ├── search-elasticsearch.sh    # 도큐먼트 조회 및 전문 검색 스크립트
│   └── clean-elasticsearch.sh     # 인덱스 도큐먼트 단독 삭제 스크립트
├── redis/                          # Redis Stack 서비스 (RedisJSON + RediSearch)
│   ├── docker-compose.yml
│   ├── .env.example
│   ├── .env
│   ├── init-redis.sh               # ACL 사용자, RediSearch 인덱스 생성 & MS SQL 자동 등록
│   ├── register-to-mssql.sh        # Redis 접속 정보를 MS SQL에 단독 등록
│   ├── search-redis.sh             # RedisJSON 키 및 데이터 조회/검색 스크립트
│   └── clean-redis.sh              # Redis 데이터 단독 삭제 스크립트
├── mssql/                          # MS SQL Server 2022 서비스
│   ├── docker-compose.yml
│   ├── .env.example
│   ├── .env
│   ├── init-mssql.sh               # DB, 계정(dbo) 생성 및 테이블 스키마 초기화
│   ├── init-mssql.sql              # DDL 및 인덱스/제약조건 정의 SQL
│   ├── search-mssql.sh             # 테이블 데이터 조회 및 검색 스크립트
│   └── clean-mssql.sh              # 테이블 데이터 단독 삭제 스크립트
├── tests/                          # 일반 사용자 권한 및 CRUD 통합 테스트
│   ├── test-storages.sh            # Bash 기반 29개 통합 테스트 스위트
│   └── test_storages.py            # Python 기반 29개 통합 테스트 스위트 (C++ 연동 규격 검증)
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
| **MS SQL** | `1433` | `1433` | `MSSQL_EXTERNAL_IP` (`127.0.0.1`) | - | `sa` (관리자)<br>`agora_user` (일반 사용자, `dbo` 권한)<br>DB: `agora_db` |
| **Elasticsearch** | `9200` | `9200` | `ES_EXTERNAL_IP` (`127.0.0.1`) | - | `elastic` (슈퍼유저)<br>`agora_user` (인덱스 전용 계정)<br>Index: `canvas` |
| **Redis Stack** | `6379`<br>`8001` (Insight) | `6379`<br>`8001` | `REDIS_BIND_IP` (`127.0.0.1`) | `REDIS_EXTERNAL_IP` (`127.0.0.1`) | `default` (관리자 암호 보호)<br>`agora_user` (ACL 계정, `canvas:*` 권한)<br>Index: `idx:canvas` |

> [!TIP]
> - **바인딩 IP vs MS SQL 등록 IP 분리**: AWS EC2 등 클라우드/NAT 환경에서는 호스트 OS에 공인 IP가 직접 바인딩되지 않아 공인 IP로 포트 바인딩 시 `cannot assign requested address` 에러가 발생합니다.
> - 따라서 Redis의 Docker 호스트 포트 수신 바인딩은 `REDIS_BIND_IP=127.0.0.1`으로 설정하고, MS SQL(`redis_server` 테이블)에 등록하여 외부 클라이언트가 찾아갈 공인 IP는 `REDIS_EXTERNAL_IP`로 명확하게 역할을 나누어 설정합니다.

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
- 테이블명(`users`, `redis_server`, `canvas_info`, `cpp_server`)은 `.env`에서 변경할 수 있습니다.

```bash
./mssql/init-mssql.sh
```

*(또는 Docker 명령어로 직접 실행)*
```bash
docker exec -i agora-mssql /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -I \
  -v DB_NAME='agora_db' -v DB_USER='agora_user' -v DB_PASSWORD="$MSSQL_PASSWORD" \
     TABLE_USERS='users' TABLE_REDIS_SERVER='redis_server' TABLE_CANVAS_INFO='canvas_info' \
     TABLE_CPP_SERVER='cpp_server' \
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

> [!NOTE]
> **참조 무결성 제약조건**: 다른 테이블에서 외래키로 참조 중인 데이터가 삭제 또는 변경될 시 명령이 취소되도록, 모든 외래키 제약조건에는 기본적으로 `ON DELETE/UPDATE NO ACTION`이 설정되어 있습니다.

#### `users` (회원 테이블)
- `user_id`: `INT IDENTITY(1,1)` (PK 자동 증가, 클러스터드 인덱스)
- `email`: `NVARCHAR(255) NOT NULL UNIQUE` (넌클러스터드 인덱스 `UQ_Users_Email`)
  - 이메일 인증을 통해 유저당 계정 소유 개수 제한
- `password_hash`: `NVARCHAR(255) NULL`
- `nickname`: `NVARCHAR(100) NOT NULL` (중복 가능)
- `tag_number`: `INT NOT NULL DEFAULT 0` (닉네임 식별 정수값)
- `role`: `NVARCHAR(10) NOT NULL DEFAULT 'ROLE_USER'` (CHECK 제약 조건: `ROLE_USER`, `ROLE_ADMIN`)
- `status`: `NVARCHAR(20) NOT NULL DEFAULT 'ACTIVE'` (CHECK 제약 조건: `ACTIVE`, `SUSPENDED`, `WITHDRAWN`)
- `oauth_provider`: `NVARCHAR(50) NULL`
- `oauth_id`: `NVARCHAR(255) NULL`
- `password_changed_at`: `DATETIME2 NULL`
- `created_at`: `DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()`
- `last_heartbeat_at`: `DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()` (실시간 서버 생존 lease 갱신 시각)
- `updated_at`: `DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()`
- **제약조건**:
  - `CK_Users_Auth`: `CHECK (password_hash IS NOT NULL OR (oauth_provider IS NOT NULL AND oauth_id IS NOT NULL))`
- **인덱스**:
  - `IX_Users_OAuth` : `(oauth_provider, oauth_id)` (조건부 필터 인덱스: `WHERE oauth_provider IS NOT NULL`)
  - `IX_Users_Nickname` : `(nickname)` (넌클러스터드 인덱스)
  - `UQ_Users_Nickname_TagNumber` : `(nickname, tag_number)` (넌클러스터드 유니크 인덱스)

#### `user_sessions` (회원 접속 세션 테이블)
- `user_id`: `INT NOT NULL` (PK 클러스터드 인덱스, FK: `users(user_id)` - `ON DELETE/UPDATE NO ACTION`)
- `cpp_server_id`: `INT NULL` (현재 접속 C++ 실시간 서버, FK: `cpp_server(server_id)` - `ON DELETE/UPDATE NO ACTION`)
- `canvas_id`: `INT NULL` (현재 접속 중인 캔버스, FK: `canvas_info(canvas_id)` - `ON DELETE/UPDATE NO ACTION`)
- `is_accessed`: `BIT NOT NULL DEFAULT 0`
- `last_login_at`: `DATETIME2 NULL`
- `updated_at`: `DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()`

#### `redis_server` (Redis 서버 인스턴스 관리)
- `redis_id`: `INT IDENTITY(1,1)` (PK 클러스터드 인덱스)
- `redis_ip`: `VARCHAR(45) NOT NULL`
- `redis_port`: `VARCHAR(10) NOT NULL`
- `is_activated`: `BIT NOT NULL DEFAULT 0`
- `created_at`: `DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()`

#### `cpp_server` (C++ 실시간 서버 인스턴스 관리)
- `server_id`: `INT IDENTITY(1,1)` (PK, 클러스터드 인덱스)
- `server_ip`: `VARCHAR(45) NOT NULL`
- `server_port`: `VARCHAR(10) NOT NULL`
- `ws_port`: `VARCHAR(10) NOT NULL` (웹소켓 포트)
- `is_activated`: `BIT NOT NULL DEFAULT 0`
- `created_at`: `DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()`

#### `canvas_info` (캔버스 서버 할당 및 상태 관리)
- `canvas_id`: `INT IDENTITY(1,1)` (PK 자동 증가, 클러스터드 인덱스)
- `redis_id`: `INT NULL` (할당된 Redis 서버, FK: `redis_server(redis_id)` - `ON DELETE/UPDATE NO ACTION`)
- `cpp_server_id`: `INT NULL` (할당된 C++ 실시간 서버, FK: `cpp_server(server_id)` - `ON DELETE/UPDATE NO ACTION`)
- `is_cached`: `BIT NOT NULL DEFAULT 0`
- `created_at`: `DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()`
- `updated_at`: `DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()`

---

### 2) Redis Stack & Elasticsearch 캔버스 데이터 모델

Redis는 `canvas:{canvas_id}` 키에 **RedisJSON 타입**으로 저장하며, Elasticsearch는 `canvas` 인덱스에 동일 구조의 도큐먼트로 저장 및 검색됩니다. 일반 Redis 문자열 `SET/GET`은 사용하지 않습니다.

```json
{
  "canvas-id": 1001,
  "canvas-name": "this is canvas",
  "admin-user-id": 1,
  "description": "this is description",
  "canvas-password-hash": "123!@#",
  "people": [1, 2, 3, 4],
  "inner-group": {
    "group-name1": [1, 2],
    "group-name2": [3, 4],
    "init-group-name": [1, 2, 3, 4],
    "admin-group": [1]
  },
  "init-group": "init-group-name"
}
```

- `canvas-id`: MS SQL에서 자동 생성 또는 관리하는 캔버스 고유 식별자 (Redis의 경우 키값 `canvas:{canvas_id}`로 사용)
- `admin-user-id`: 캔버스를 소유한 이용자 아이디
- `description`: 캔버스 설명 텍스트
- `canvas-password-hash`: 비밀번호 해시 (공백인 경우 퍼블릭 캔버스)
- `people`: 캔버스에 참여 중인 사용자 id 리스트 (`[1, 2, 3, 4]`)
- `inner-group`: 키(문자열 그룹명) : 값(사용자 아이디 리스트)
- `init-group`: 기본 할당 그룹명

> [!NOTE]
> 확장성(Scalability) 확보를 위해 캔버스 내 `items`(도형, 텍스트 등)는 캔버스 메타데이터 도큐먼트에 중첩(Nested)시키지 않고 애플리케이션 단에서 `canvas:{canvas_id}:item:{item_id}` 형태의 독립된 문서/키로 분리 저장하여 관리합니다.

---

## 🧪 4. 통합 검증 테스트 (29개 항목)

초기화 완료 후, 생성된 일반 사용자 계정(`agora_user`)으로 각 저장소의 연결, 권한 격리 및 CRUD/검색 동작을 자동화된 테스트 코드로 일괄 검증할 수 있습니다.
모든 테스트는 격리된 테스트 레코드를 생성하고 테스트 완료 후 **자동 롤백/클린업**합니다.

### 방법 A: Bash 테스트 스크립트 실행
별도 패키지 설치 없이 Docker 및 기본 curl/bash 도구로 검증합니다.
```bash
./tests/test-storages.sh
```

### 방법 B: Python 테스트 스크립트 실행 (C++ 연동 규격 검증)
Python 3 표준 라이브러리(urllib, subprocess, json) 기반으로 작성되어 pip 설치 없이 즉시 실행 가능합니다.
```bash
python3 tests/test_storages.py
```

### 📋 테스트 검증 항목 (총 29개)

| 저장소 | 대상 계정 | 번호 | 검증 항목 | 상세 내용 |
| :--- | :--- | :---: | :--- | :--- |
| **MS SQL** | `agora_user` | 1 | 계정 인증 및 DB 소유권 | `agora_db`에 대한 `dbo` 소유권 확인 |
| | | 2 | 테이블 생성 확인 | `users`, `redis_server`, `canvas_info`, `cpp_server` 존재 여부 |
| | | 3 | 회원 [Create] | `users` 테이블 테스트 회원 INSERT (`is_accessed`, `cpp_server_id` FK 포함) |
| | | 4 | 회원 [Read] | 회원 조회 및 `status = 'ACTIVE'` 확인 |
| | | 5 | 회원 [Update] | 회원 `status`를 `SUSPENDED`, `is_accessed`를 `0`으로 수정 확인 |
| | | 6 | 회원 [Delete] | 테스트 회원 데이터 삭제 (클린업) |
| | | 7 | 캔버스/Redis [Create] | `redis_server` (`is_activated: 1`) 및 `canvas_info` (PK: 9999, Redis FK 연동) INSERT |
| | | 8 | 캔버스 [Read] | `canvas_info` 조회 및 `is_cached = 0` 확인 |
| | | 9 | 캔버스 [Update] | `canvas_info`의 `is_cached`를 `1`로 수정 확인 |
| | | 10 | 캔버스/Redis [Delete] | 캔버스 정보 및 Redis 서버 테스트 데이터 삭제 (클린업) |
| | | 11 | C++ 실시간 서버 [Create] | `cpp_server` 테이블 테스트 서버 인스턴스 INSERT (`is_activated: 1`) |
| | | 12 | C++ 실시간 서버 [Read] | C++ 실시간 서버 포트(7077) 조회 확인 |
| | | 13 | C++ 실시간 서버 [Update] | C++ 실시간 서버 포트(7077 -> 8080) 수정 확인 |
| | | 14 | C++ 실시간 서버 [Delete] | C++ 실시간 서버 테스트 데이터 삭제 (클린업) |
| **Elasticsearch** | `agora_user` | 15 | 계정 인증 및 역할 | Basic 인증 및 `agora_user_role` 역할 매핑 확인 |
| | | 16 | 인덱스 접근 권한 | `canvas` 인덱스 접근 및 클러스터 상태 확인 |
| | | 17 | 도큐먼트 [Create] | `canvas` 인덱스에 신규 캔버스 JSON 도큐먼트 색인 |
| | | 18 | 도큐먼트 [Read] | Document ID 기반 단건 조회 및 `admin-user-id` 확인 |
| | | 19 | 검색 쿼리 [Search] | `description` 필드 전문 검색 동작 확인 |
| | | 20 | 도큐먼트 [Update] | `canvas-password-hash` 공백 변경 (퍼블릭 캔버스) 및 버전 증가 확인 |
| | | 21 | 도큐먼트 [Delete] | 테스트 도큐먼트 삭제 (클린업) |
| **Redis Stack** | `agora_user` | 22 | ACL 인증 | `AUTH agora_user` 및 `PING -> PONG` 확인 |
| | | 23 | RediSearch 인덱스 | `FT.INFO idx:canvas` 인덱스 메타데이터 확인 |
| | | 24 | RedisJSON [Create] | `JSON.SET canvas:test-py $ <json>` 신규 캔버스 JSON 생성 확인 |
| | | 25 | RedisJSON [Read] | `JSON.GET canvas:test-py` 데이터 조회 및 `admin-user-id` 확인 |
| | | 26 | RediSearch [Search] | `FT.SEARCH idx:canvas @admin_user_id` 전문 검색 쿼리 확인 |
| | | 27 | RedisJSON [Update] | `JSON.SET canvas:test-py $["admin-user-id"] 2000` 필드 수정 확인 |
| | | 28 | RedisJSON [Delete] | `DEL canvas:test-py` 삭제 확인 (클린업) |
| | | 29 | 보안 격리 [Scope] | 허용되지 않은 키(`other:unauthorized`) 쓰기 시 `NOPERM` 차단 확인 |

---

## 🔍 5. 저장소 데이터 조회 및 검색 (Data Search & Inspection)

각 저장소에 적재된 데이터의 상태를 확인하거나 키워드로 검색할 수 있는 도구를 제공합니다. 전체 저장소를 한 번에 조회하거나, 각 저장소 폴더에 분리된 전용 스크립트로 개별 조회할 수 있습니다.

### 방법 A: 전체 저장소 통합 검색 (프로젝트 루트)
모든 저장소(MS SQL, Elasticsearch, Redis)의 데이터를 한 번에 대시보드 형태로 출력하거나 공통 키워드로 검색합니다.

```bash
# 1. 전체 저장소 데이터 대시보드 일괄 출력
./search-storages.sh
# (또는 Python)
python3 search_storages.py

# 2. 전 저장소 대상 키워드 검색
./search-storages.sh -q "검색어"
# (또는 Python)
python3 search_storages.py -q "검색어"
```

### 방법 B: 저장소별 개별 폴더 분리 검색
각 데이터베이스 디렉터리(`mssql/`, `elasticsearch/`, `redis/`) 내에 단독 실행 가능한 스크립트가 분리되어 있습니다.

#### (1) MS SQL Server (`mssql/search-mssql.sh`)
```bash
# 전체 테이블(users, user_sessions, canvas_info, redis_server, cpp_server) 레코드 목록 출력
./mssql/search-mssql.sh

# 특정 테이블만 조회
./mssql/search-mssql.sh -t users

# 특정 키워드(이메일, 닉네임, IP 등) 검색
./mssql/search-mssql.sh -q "admin@agora.com"
```

#### (2) Elasticsearch (`elasticsearch/search-elasticsearch.sh`)
```bash
# canvas 인덱스 전체 도큐먼트 목록 출력
./elasticsearch/search-elasticsearch.sh

# canvas-name, description 대상 전문 검색
./elasticsearch/search-elasticsearch.sh -q "whiteboard"

# 특정 도큐먼트 ID 단건 상세 조회
./elasticsearch/search-elasticsearch.sh -i "doc-101"
```

#### (3) Redis Stack (`redis/search-redis.sh`)
```bash
# canvas:* 네임스페이스 키 및 JSON 데이터 전체 목록 출력
./redis/search-redis.sh

# RediSearch 인덱스(idx:canvas) 전문 검색
./redis/search-redis.sh -q "Alpha"

# 특정 단일 키 상세 조회
./redis/search-redis.sh -k "canvas:101"
```

---

## 🧹 6. 저장소 데이터 삭제 및 초기화 (Data Cleanup)

개발 및 테스트 진행 중 저장소에 적재된 데이터를 테이블 스키마, 외래키 제약조건, RediSearch/Elasticsearch 인덱스 매핑 손상 없이 **안전하게 초기화**할 수 있습니다.

### 동작 원리
1. **MS SQL Server**:
   - 외래키 참조 순서(`user_sessions` → `canvas_info` → `users` → `cpp_server` → `redis_server`)를 준수하여 트랜잭션 내에서 데이터를 일괄 삭제합니다.
   - 각 테이블의 `IDENTITY` 자동 증가 시드를 `0`으로 재설정(`DBCC CHECKIDENT(..., RESEED, 0)`)하여 신규 데이터 생성 시 ID가 `1`부터 다시 시작되도록 보장합니다.
   - 기본적으로 현재 실행 중인 Redis 인스턴스 정보(`redis/.env` 기준)를 `redis_server` 테이블에 자동 재등록하여 시스템을 즉시 구동 가능한 상태로 유지합니다.
2. **Elasticsearch**:
   - 인덱스 삭제(`DELETE /canvas`) 대신 `_delete_by_query` (`match_all`)를 사용하여 사전에 설정된 필드 매핑, 동적 템플릿, 사용자 권한을 100% 보존하면서 저장된 도큐먼트만 고속으로 일괄 삭제합니다.
3. **Redis Stack**:
   - `FLUSHDB` 시 RediSearch 인덱스 정의(`idx:canvas`)가 드롭되는 문제를 방지하기 위해, 네임스페이스(`canvas:*`) 키만 원자적(Lua 스크립트)으로 안전 삭제합니다.
   - 인덱스 메타데이터 부재 시 자동으로 `FT.CREATE`를 재호출하는 자가 복구 메커니즘이 내장되어 있습니다.

### 실행 방법

#### 방법 A: 전체 저장소 일괄 삭제 (프로젝트 루트)
```bash
# 1. 대화형 실행 (실행 전 확인 프롬프트 노출)
./clean-storages.sh

# 2. 비대화형 강제 실행 (CI/CD 또는 자동화 스크립트용)
./clean-storages.sh -y

# 3. Python 스크립트 실행
python3 clean_storages.py -y
```

#### 방법 B: 저장소별 개별 폴더 분리 삭제
각 스토리지 디렉터리에서 원하는 DB만 선택적으로 초기화할 수 있습니다:

```bash
# 1. MS SQL 테이블 데이터만 단독 초기화
./mssql/clean-mssql.sh -y

# 2. Elasticsearch 인덱스 도큐먼트만 단독 초기화
./elasticsearch/clean-elasticsearch.sh -y

# 3. Redis Stack 캔버스 캐시 데이터만 단독 초기화
./redis/clean-redis.sh -y
```

### ⚙️ 옵션 안내
- `-y`, `--yes`, `--force`: 삭제 확인 프롬프트를 생략하고 즉시 삭제를 진행합니다.
- `--no-re-register`: MS SQL 초기화 후 Redis 서버 엔드포인트 자동 재등록을 건너뜁니다.
- `-h`, `--help`: 도움말을 출력합니다.
