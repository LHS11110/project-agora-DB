# Project Agora DB

Project Agora의 저장소 인프라입니다. 기본 Docker Compose 구성은 개발용 단일 노드입니다. 클러스터 배포 템플릿은 MS SQL Server Availability Group과 Redis Sentinel HA 구성으로 별도 제공합니다. 애플리케이션 계정, 스키마, RedisJSON/RediSearch, Elasticsearch 인덱스를 초기화합니다.

애플리케이션 및 실시간 서버는 [Project Agora BE](../project-agora-BE)에서 실행합니다.

## 구성

| 저장소 | 역할 | 컨테이너 | 기본 로컬 포트 |
| --- | --- | --- | --- |
| MS SQL Server 2022 CU26 | 사용자, 세션, 캔버스 배정, C++·Redis 서버 메타데이터 | `agora-mssql` | `1433` |
| Redis 8.6.7 | 활성 캔버스 RedisJSON, RediSearch | `agora-redis-stack` | `6379` |
| Redis Insight 3.8.0 | Redis 관리 UI | `agora-redis-insight` | `8001` |
| Elasticsearch 8.19.22 | 캔버스 문서, 백엔드 애플리케이션 로그 | `agora-elasticsearch` | `9200` |

기본 단일 노드 구성의 세 서비스는 Compose 네트워크 `agora-net`을 공유합니다. 기본값은 호스트의 loopback에만 DB, Redis, Elasticsearch를 바인딩합니다. HA 구성은 별도 Compose 네트워크와 노드 구성을 사용합니다.

```mermaid
flowchart LR
    BE[Project Agora BE] --> MSSQL[(MS SQL Server)]
    BE --> Redis[(Redis Stack)]
    BE --> ES[(Elasticsearch)]
    MSSQL -->|redis_server 배정 정보| Redis
    MSSQL -->|cpp_server heartbeat·canvas_info| BE
    Redis -->|활성 캔버스 문서| BE
    BE -->|캔버스 영구 저장·애플리케이션 로그| ES
```

## 빠른 시작

### 1. 환경 파일 준비

각 서비스는 독립 환경 파일을 사용합니다. 예시 파일을 복사한 뒤 모든 placeholder 값을 충분히 긴 난수로 교체합니다. Redis와 Elasticsearch 비밀번호는 `openssl rand -hex 32`로 만들 수 있습니다. SQL Server `MSSQL_SA_PASSWORD`는 최소 8자이며 대문자·소문자·숫자·기호 중 세 종류가 필요합니다. 예를 들어 `printf 'A9!%s\n' "$(openssl rand -hex 32)"`로 생성하면 이 정책을 충족합니다.

```bash
cd /path/to/project-agora-DB
cp mssql/.env.example mssql/.env
cp redis/.env.example redis/.env
cp elasticsearch/.env.example elasticsearch/.env
chmod 600 mssql/.env redis/.env elasticsearch/.env
./elasticsearch/prepare-storage.sh
```

| 파일 | 필수 비밀값 |
| --- | --- |
| `mssql/.env` | `MSSQL_SA_PASSWORD`, `MSSQL_PASSWORD` |
| `redis/.env` | `REDIS_PASSWORD`, `REDIS_USER_PASSWORD` |
| `elasticsearch/.env` | `ELASTIC_PASSWORD`, `ES_USER_PASSWORD`, `ES_LOG_USER_PASSWORD` |

비밀번호는 Git에 추가하지 않습니다. BE의 `DB_PASSWORD`, `REDIS_USER_PASSWORD`, `REDIS_SENTINEL_PASSWORD`, `ES_USER_PASSWORD`, `ES_LOG_USER_PASSWORD`는 DB 설정과 일치해야 합니다. 예시 비밀번호는 실제 배포 전에 서비스별로 별도의 안전한 난수로 교체합니다. 운영 환경은 비밀 저장소에서 프로세스 환경변수로 주입하고 `.env`는 소유자 전용 권한(`0600`)으로 유지하세요.

SQL Server CA 인증서를 사용하면 `mssql/.env`에서 `MSSQL_TLS_ENABLED=true`로 설정하고 인증서와 키를 `MSSQL_TLS_CERTS_DIR`에 `server.crt`, `server.key` 이름으로 둡니다. 인증서와 개인 키는 컨테이너 내부의 `mssql` 사용자(UID 10001)가 읽을 수 있어야 하며, 인증서 SAN에 AG listener 이름과 연결에 사용하는 호스트명이 포함되어야 합니다. 개발용 단일 노드에서만 자체 서명 인증서 신뢰 우회 설정을 사용하세요.

Elasticsearch HTTPS를 사용하면 CA 서명 인증서 파일을 `elasticsearch/certs/http.crt`, 개인 키를 `http.key`, 발급 CA를 `ca.crt`로 두고 `ES_HTTP_TLS_ENABLED=true`, `ES_SCHEME=https`, `ES_CA_CERT`를 설정합니다. ES 호스트 포트는 실제 CA 검증에 사용하는 호스트 이름으로 BE에 지정해야 합니다. Elasticsearch 로그 저장소는 기본 90일 ILM 보존과 35일 일일 snapshot 정책을 사용합니다. `ES_SNAPSHOT_HOST_DIR`은 컨테이너와 별도 백업 매체에 마운트하고, Elasticsearch 컨테이너 UID 1000이 쓸 수 있게 준비합니다.

### 2. 컨테이너 실행

```bash
docker compose up -d
docker compose ps
```

`mssql-init`은 MS SQL health check 이후 스키마를 적용하는 일회성 컨테이너입니다. 상태와 로그를 확인합니다.

```bash
docker compose logs mssql-init
docker compose ps
```

### 3. 초기화 재실행 또는 개별 초기화

초기화 스크립트는 반복 실행할 수 있도록 작성되었습니다. 마이그레이션을 다시 적용하거나 컨테이너 밖에서 초기화할 때 사용합니다.

```bash
./mssql/init-mssql.sh
./redis/init-redis.sh
./elasticsearch/init-elasticsearch.sh
```

초기화 스크립트는 `MSSQL_USER`를 `agora_runtime` DML 역할에 넣고 DB 소유자는 `sa`로 둡니다. 서버 스키마 변경은 관리자 연결로만 수행합니다. Sentinel HA를 쓸 때는 Redis `.env`의 `REDIS_SENTINEL_USER`/`REDIS_SENTINEL_PASSWORD`와 BE 환경변수 값을 일치시킵니다. 이 ACL 계정에는 primary 주소 조회만 허용합니다.

기존 `ES_LOG_INDEX`가 구체적인 Elasticsearch 인덱스라면 쓰기 alias로 바로 바꾸지 않습니다. BE/C++ 로그 기록을 중지하고 먼저 스냅샷을 만든 다음 아래 마이그레이션을 실행합니다. 스크립트는 문서 수를 확인하고 alias 전환을 원자적으로 수행합니다.

```bash
./elasticsearch/snapshot-elasticsearch.sh
ES_ALLOW_LOG_INDEX_MIGRATION=true ./elasticsearch/migrate-log-index-to-ilm.sh
./elasticsearch/init-elasticsearch.sh
```

운영 배포에서 외부 연결이 필요하면 Elasticsearch TLS와 SQL Server TLS를 모두 구성하고 BE/C++에서 CA 검증을 사용합니다. Redis/Sentinel은 앱·DB 호스트 사이의 사설망으로만 연결하고 호스트 방화벽/보안 그룹은 필요한 앱·복제·관리 주소만 허용합니다. 기본 Compose 바인딩은 loopback입니다.

초기화 후 BE 실행 방법은 [Project Agora BE README](../project-agora-BE/README.md)를 참고하세요.

## 클러스터 구성

현재 SQL Server 스키마와 Redis 키/JSON 형식은 유지합니다. 클러스터 구성은 기본 단일 노드 Compose와 별도 실행합니다.

### MS SQL Server

[SQL Server AG 배포 안내](mssql/cluster/README.md)의 노드 Compose를 각 Linux 호스트에서 실행합니다. 이 저장소의 단일 DB에 맞춰 Standard Basic Availability Group 데이터 복제본 2개와 Express 설정 전용 복제본 1개를 사용합니다. 운영 HA에는 호스트 Pacemaker와 fencing 구성이 필요합니다. AG listener를 기존 `DB_HOST` 및 관리 스크립트의 접속 주소로 사용합니다.

### Redis Stack HA

기존 `FT.SEARCH`/RedisJSON 기능을 유지하기 위해 OSS Redis Cluster 샤딩 대신 Sentinel 기반 primary/replica failover를 제공합니다. Redis OSS Cluster API는 현재 RediSearch 검색 기능과 호환되지 않습니다. Sentinel은 데이터를 샤딩하지 않으며, 기존 Redis 명령과 단일 키 구조를 유지합니다.

기존 단일 Redis 데이터는 새 Compose 볼륨에 자동 복사되지 않으므로, [Redis HA 마이그레이션 안내](redis/cluster/README.md)에 따라 snapshot을 옮긴 뒤 전환합니다. 개발/검증용으로 한 호스트에 노드가 함께 올라오므로, 이 구성만으로 호스트 장애까지 보호하지는 않습니다.

실제 호스트 장애 대응은 [Redis 다중 호스트 배포 절차](redis/cluster/README.md)의 `docker-compose.ha-node.yml`을 각 Redis 호스트에서 실행합니다. `docker-compose.sentinel.yml`은 단일 호스트 failover 검증용입니다.

```bash
./redis/snapshot-standalone.sh
docker compose stop redis-stack
docker compose --env-file redis/.env -f redis/docker-compose.sentinel.yml create redis-primary
docker cp /tmp/agora-redis-dump.rdb agora-redis-primary:/data/dump.rdb
docker compose --env-file redis/.env -f redis/docker-compose.sentinel.yml up -d
./redis/init-redis-sentinel.sh
```

이 구성은 Redis 노드 3개와 Sentinel 3개를 사용합니다. `redis_server` 행은 기존 스키마 호환을 위해 초기 endpoint와 논리 서비스 ID를 등록하지만, `REDIS_SENTINELS`가 설정된 BE/C++은 이 행의 IP·포트로 접속하지 않고 Sentinel에서 현재 primary를 조회합니다. C++은 연결을 다시 열 때마다 primary를 재탐색하고, Spring은 캔버스 Redis 문서를 읽을 때 primary를 재탐색합니다. 두 클라이언트 모두 후보 노드의 `ROLE`이 `master`인지 확인합니다. 따라서 failover 뒤 `redis_server` 행을 수동 갱신할 필요가 없습니다. Sentinel 인증이 활성화된 운영 환경에서는 `REDIS_SENTINEL_USER`/`REDIS_SENTINEL_PASSWORD`를 Redis와 BE에 설정하고 일치시켜야 합니다. Sentinel 포트(26379–26381)는 신뢰할 수 있는 사설망에서만 열어야 합니다. 운영에서 호스트 장애도 견디려면 Redis 노드와 Sentinel을 서로 다른 호스트에 분산하고, 각 노드가 서로 및 클라이언트에서 접근 가능한 주소를 광고하도록 배포해야 합니다. Redis 저장소 조회·정리 도구는 HA 노드 중 현재 primary를 찾아 실행합니다.

백엔드가 처리할 구체적인 연결 및 장애조치 요구 사항은 [백엔드 클러스터 전환 요구 사항](#백엔드-클러스터-전환-요구-사항)을 참고하세요.

## 장애조치 시험

### Redis Sentinel 로컬 시험

단일 호스트에서 Redis primary 장애 감지, Sentinel 승격, 복귀 replica 동기화를 확인합니다. 기본 단일 노드 Redis가 포트 `6379`를 사용 중이면 먼저 중지한 뒤 실행합니다.

```bash
docker compose stop redis-stack
docker compose --env-file redis/.env -f redis/docker-compose.sentinel.yml up -d
./redis/init-redis-sentinel.sh
./redis/test-failover.sh
```

시험 스크립트는 현재 primary를 찾아 임시 캔버스 JSON을 애플리케이션 ACL 계정으로 저장하고 두 replica에 복제될 때까지 기다립니다. `redis/.env`에 Sentinel 전용 계정이 설정되어 있으면 topology 조회에도 그 인증을 사용합니다. 그 다음 primary 컨테이너를 중지해 자동 failover를 유도하고, 세 Sentinel의 primary 조회 결과와 승격 후 RedisJSON/RediSearch 접근을 확인합니다. 원래 primary를 다시 시작해 3노드가 복구되는지 확인한 뒤 임시 키를 삭제합니다. 이 스크립트는 로컬 `docker-compose.sentinel.yml` 전용이며, 실제 서비스 노드에서 실행하지 않습니다. 자세한 구성은 [Redis Sentinel 시험·마이그레이션 안내](redis/cluster/README.md)를 참고하세요.

### SQL Server AG 계획된 시험

SQL Server AG는 Pacemaker가 관리하므로 AG 리소스가 있는 Linux 호스트에서 Pacemaker 명령으로 계획된 failover를 실행합니다. 먼저 두 데이터 replica가 online이고 승격 대상이 synchronous 상태인지, listener를 통해 DB에 접속되는지 확인합니다. 계획된 전환에는 아래처럼 실제 Pacemaker 리소스 이름과 대상 노드 이름을 사용합니다.

```bash
sudo pcs status --full
sudo pcs resource move <AG-resource>-master <target-pacemaker-node> --master --lifetime=30S

# listener를 통해 새 primary를 확인 (접속 인자와 비밀번호는 환경에 맞게 전달)
sqlcmd -S tcp:<AG-listener>,<port> -d agora_db -U <user> \
  -Q "SELECT @@SERVERNAME AS primary_instance, sys.fn_hadr_is_primary_replica(N'agora_db') AS is_primary;"

sudo pcs resource clear <AG-resource>-master
sudo pcs status --full
```

조회 결과의 `is_primary`가 `1`이고 Pacemaker가 새 primary와 listener를 정상 상태로 보고하는지 확인합니다. 이어서 BE/C++를 통해 DB 쓰기 요청을 보내 끊긴 연결이 listener에 재연결되는지 확인합니다. `CLUSTER_TYPE=EXTERNAL` AG는 SQL `ALTER AVAILABILITY GROUP ... FAILOVER`로 전환하지 않습니다. 비동기 replica로의 forced failover는 데이터 유실 가능성이 있으므로 일반 시험 절차로 사용하지 않습니다. Pacemaker fencing이 동작하는 격리된 스테이징 환경에서는 primary 호스트를 종료해 자동 failover도 별도로 확인할 수 있습니다. 배포 환경에 맞춘 절차는 [SQL Server AG 안내](mssql/cluster/README.md)에 있습니다.

## 환경 변수

### MS SQL Server — `mssql/.env`

| 변수 | 설명 |
| --- | --- |
| `MSSQL_SA_PASSWORD` | SQL Server 관리자 비밀번호 |
| `MSSQL_PID` | 라이선스 에디션. 기본 `Express` |
| `TIMEZONE` | 컨테이너 시간대 |
| `MSSQL_DB` | 데이터베이스 이름, 기본 `agora_db` |
| `MSSQL_USER`, `MSSQL_PASSWORD` | BE·C++가 사용하는 DML 전용 런타임 계정 (`agora_runtime` 역할) |
| `DB_TRUST_SERVER_CERTIFICATE` | 개발용 자체 서명 인증서 예외. 운영에서는 `false` |
| `MSSQL_TLS_ENABLED`, `MSSQL_TLS_CERTS_DIR` | SQL Server TLS 인증서 설정. 운영에서는 `true` |
| `MSSQL_PORT`, `MSSQL_EXTERNAL_IP`, `MSSQL_EXTERNAL_PORT` | 내부 포트와 호스트 포트 바인딩 |
| `MSSQL_TABLE_USERS`, `MSSQL_TABLE_REDIS_SERVER` | 사용자·Redis 서버 테이블 이름 |
| `MSSQL_TABLE_CANVAS_INFO`, `MSSQL_TABLE_CPP_SERVER` | 캔버스·C++ 서버 테이블 이름 |

### Redis 8 — `redis/.env`

| 변수 | 설명 |
| --- | --- |
| `REDIS_PASSWORD` | Redis 기본 사용자 비밀번호 및 health check 용도 |
| `REDIS_USER`, `REDIS_USER_PASSWORD` | `canvas:*` 범위로 제한된 애플리케이션 ACL 계정 |
| `REDIS_SENTINEL_USER`, `REDIS_SENTINEL_PASSWORD` | Sentinel primary 조회 전용 계정. 클라이언트도 같은 값을 사용 |
| `TIMEZONE` | 컨테이너 시간대 |
| `REDIS_INDEX_NAME` | 기본 `idx:canvas` |
| `REDIS_KEY_PREFIX` | 기본 `canvas:` |
| `REDIS_PORT`, `REDIS_BIND_IP`, `REDIS_EXTERNAL_IP`, `REDIS_EXTERNAL_PORT` | Redis 포트와 호스트 바인딩·등록 주소 |
| `REDIS_INSIGHT_PORT` | Redis Insight 포트 |

### Elasticsearch — `elasticsearch/.env`

| 변수 | 설명 |
| --- | --- |
| `ELASTIC_PASSWORD` | `elastic` 관리자 비밀번호 |
| `TIMEZONE` | 컨테이너 시간대 |
| `ES_INDEX` | 캔버스 인덱스, 기본 `canvas` |
| `ES_USER_NAME`, `ES_USER_PASSWORD` | BE·C++가 사용하는 애플리케이션 사용자 |
| `ES_LOG_INDEX` | BE 로그 인덱스, 기본 `agora-logs` |
| `ES_LOG_USER_NAME`, `ES_LOG_USER_PASSWORD` | 로그 인덱스에 문서 추가만 가능한 별도 BE 계정 |
| `ES_EXTERNAL_IP`, `ES_EXTERNAL_PORT` | 호스트 포트 바인딩 |
| `ES_HTTP_TLS_ENABLED`, `ES_TLS_CERTS_DIR`, `ES_SCHEME`, `ES_CA_CERT` | Elasticsearch HTTPS와 인증서 검증 설정 |
| `ES_SNAPSHOT_HOST_DIR`, `ES_LOG_RETENTION_DAYS` | Elasticsearch snapshot 디렉터리와 로그 문서 보존 기간 |
| `ES_JAVA_MIN_MEM`, `ES_JAVA_MAX_MEM` | Elasticsearch JVM 메모리 |

## 데이터 모델과 수명 주기

MS SQL은 관계형 메타데이터와 현재 배정 상태를 보관합니다.

| 테이블 | 용도 |
| --- | --- |
| `users` | 이메일, BCrypt 비밀번호 해시, 닉네임·태그, 역할, 상태 |
| `user_sessions` | 사용자별 현재 접속 여부, 캔버스, C++ 서버 참조 |
| `redis_server` | 사용 가능한 Redis 인스턴스 |
| `cpp_server` | C++ REST/WS 포트, 활성 여부, `last_heartbeat_at` |
| `canvas_info` | Redis·C++ 서버 배정 및 `is_cached` 상태 |

캔버스 본문은 Elasticsearch에 영구 저장하고, 접속 중에는 RedisJSON의 `canvas:{canvasId}` 키에 둡니다. C++ 서버가 마지막 접속자를 확인하면 RedisJSON 문서를 Elasticsearch로 저장하고 Redis 키 및 `canvas_info` 배정을 해제합니다.

`cpp_server`의 식별자는 `(server_ip, server_port)`입니다. C++ 서버가 5초마다 heartbeat를 갱신하며 BE는 최신 heartbeat와 health check를 모두 만족한 서버만 할당합니다.

## 운영 명령

```bash
# 전체 상태와 로그
docker compose ps
docker compose logs -f mssql redis-stack elasticsearch

# 컨테이너 중지·재시작 — 데이터 볼륨 유지
docker compose stop
docker compose start

# Compose 설정 검증
docker compose config -q
```

데이터 볼륨을 포함한 완전 초기화는 되돌릴 수 없습니다. 일반적인 개발 데이터 정리는 아래 스크립트를 먼저 사용하세요.

```bash
# 확인 후 전체 테스트 데이터 정리
./clean-storages.sh

# 확인 없이 실행 — 현재 데이터에 영향을 주므로 주의
./clean-storages.sh -y

# 저장소별 정리
./mssql/clean-mssql.sh -y
./redis/clean-redis.sh -y
./elasticsearch/clean-elasticsearch.sh -y
```

## 점검과 검색

```bash
# 세 저장소의 애플리케이션 계정, CRUD, 권한 검증
python3 tests/test_storages.py

# 전체 저장소 조회 또는 키워드 검색
./search-storages.sh
./search-storages.sh -q "keyword"

# 저장소별 조회
./mssql/search-mssql.sh
./redis/search-redis.sh
./elasticsearch/search-elasticsearch.sh
```

`tests/test_storages.py`는 임시 사용자, 캔버스, 문서를 만들고 테스트 종료 시 삭제합니다. 운영 데이터가 있는 환경에서는 테스트 전 백업과 실행 대상 확인이 필요합니다.

## BE 연결 설정

BE 루트 `.env`에는 이 저장소의 애플리케이션 계정 정보를 전달합니다.

```dotenv
DB_HOST=127.0.0.1
DB_PORT=1433
DB_NAME=agora_db
DB_USER=<MSSQL_USER>
DB_PASSWORD=<MSSQL_PASSWORD>
DB_ENCRYPT=true
DB_TRUST_SERVER_CERTIFICATE=false
DB_FREETDS_CONF=/etc/freetds/freetds.conf

REDIS_USER=<REDIS_USER>
REDIS_USER_PASSWORD=<REDIS_USER_PASSWORD>
REDIS_SENTINEL_USER=<REDIS_SENTINEL_USER>
REDIS_SENTINEL_PASSWORD=<REDIS_SENTINEL_PASSWORD>

ES_HOST=127.0.0.1
ES_PORT=9200
ES_SCHEME=https
ES_CA_CERT=/run/secrets/elasticsearch-ca.crt
ES_INDEX=<ES_INDEX>
ES_USER_NAME=<ES_USER_NAME>
ES_USER_PASSWORD=<ES_USER_PASSWORD>

ES_LOG_INDEX=<ES_LOG_INDEX>
ES_LOG_USER_NAME=<ES_LOG_USER_NAME>
ES_LOG_USER_PASSWORD=<ES_LOG_USER_PASSWORD>
```

캔버스 데이터용 `ES_USER_NAME`과 `ES_USER_PASSWORD`는 기존 인덱스에 사용하고, 백엔드 애플리케이션 로그는 MS SQL 스키마와 분리해 별도 `ES_LOG_INDEX`에 `ES_LOG_USER_NAME`/`ES_LOG_USER_PASSWORD`로 기록합니다. 초기화 스크립트가 로그 인덱스와 전용 계정을 생성합니다. 이 역할은 지정된 로그 인덱스에 문서 생성 및 동적 매핑 권한만 가지며 조회·수정·삭제나 다른 인덱스 접근 권한은 없습니다. 로그 전송은 자동 ID 또는 Elasticsearch create/op_type=create 방식으로 append-only 저장해야 하며, 로그 조회는 별도 운영 계정을 사용합니다.

새 로그 문서는 쓰기 alias에 추가되며 ILM이 1일 또는 primary shard 10GB 기준으로 회전하고 기본 90일 후 backing index를 삭제합니다. SLM은 매일 UTC 02:30 캔버스와 로그 인덱스를 snapshot하고 35일간 보존합니다. snapshot 저장소는 같은 호스트의 Compose 데이터 볼륨과 분리된 내구성 볼륨/백업 매체에 보관하고, 복원은 새 Elasticsearch 환경에서 아래처럼 수행합니다.

```bash
ES_RESTORE_SNAPSHOT=agora-snapshot-20260925 ./elasticsearch/restore-elasticsearch.sh
```

SQL Server 백업은 AG primary에서 생성하고, Redis HA 백업은 Sentinel이 보고하는 primary의 RDB를 별도 저장소에 복사합니다. 백업 생성만으로 복구 가능성이 증명되지는 않으므로 운영 전 새 환경에서 SQL, Redis, Elasticsearch와 애플리케이션 로그를 복원하고 BE 연결까지 확인합니다.

현재 BE와 C++은 DB 등록 정보로 Redis 서비스의 논리 ID를 찾습니다. 단일 노드에서는 Redis 컨테이너를 시작한 뒤 `./redis/init-redis.sh`를 실행해 Redis 사용자, 색인, `redis_server` 등록을 완료해야 합니다. Sentinel 모드에서는 `REDIS_SENTINELS`와 `REDIS_SENTINEL_MASTER_NAME`이 실제 Redis 접속 대상을 결정합니다. 아래에는 앱에서 유지해야 하는 HA 연결 동작과 남은 운영 검증 항목을 정리했습니다.

## 백엔드 클러스터 전환 요구 사항

BE와 C++ 실시간 서버는 아래 SQL listener 및 Redis Sentinel 설정을 지원합니다. SQL 스키마, `canvas:{canvasId}` 키, RedisJSON 문서, RediSearch 색인, Elasticsearch 저장 흐름은 유지합니다. 실제 listener/seed 주소와 인증서·비밀번호는 배포 환경에서 주입해야 합니다.

### SQL Server Availability Group

- `DB_HOST`에는 개별 SQL Server 호스트가 아니라 AG listener의 DNS 이름 또는 가상 IP를 설정하고, `DB_PORT`에는 listener 포트를 설정합니다. 현재 `DB_NAME`, 사용자, 비밀번호와 쿼리·스키마는 그대로 사용합니다.
- 연결 풀은 장애조치 때 끊긴 TCP 세션을 폐기하고 listener로 새 연결을 만들어야 합니다. 연결 실패는 제한된 횟수와 backoff로 재시도합니다. AG listener와 클라이언트의 재연결 동작은 [SQL Server Linux AG 문서](https://learn.microsoft.com/en-us/sql/linux/sql-server-linux-availability-group-overview?view=sql-server-ver17)를 따릅니다.
- 쓰기 요청은 listener를 통해 현재 primary로 보내야 합니다. 재시도할 때는 기존 트랜잭션을 폐기한 뒤 작업 전체를 다시 시작하고, 커밋 여부가 불분명하거나 중복 수행에 안전하지 않은 작업은 무조건 재실행하지 않습니다.

### Redis Sentinel

- BE와 C++은 Redis Sentinel을 지원하는 클라이언트를 사용합니다. Redis Cluster 슬롯 검색 모드가 아니라 Sentinel discovery를 사용합니다. Sentinel 클라이언트는 Sentinel seed에 질의해 현재 primary 주소를 조회해야 합니다([Redis Sentinel client 문서](https://redis.io/docs/latest/develop/reference/sentinel-clients/)).
- 설정에는 접근 가능한 Sentinel 주소 전체(운영 구성 기준 3개, 포트 `26379`)와 master 이름 `agora-master`, Redis ACL 계정 및 비밀번호가 필요합니다. 예시 변수명은 아래와 같으며 실제 이름은 애플리케이션 설정 규칙에 맞춥니다.

  ```dotenv
  REDIS_SENTINELS=10.0.0.21:26379,10.0.0.22:26379,10.0.0.23:26379
  REDIS_SENTINEL_MASTER_NAME=agora-master
  REDIS_USER=<REDIS_USER>
  REDIS_USER_PASSWORD=<REDIS_USER_PASSWORD>
  ```

- 쓰기 연결은 Sentinel이 알려준 현재 primary를 사용합니다. 연결 끊김이나 replica 승격 후 기존 연결 풀을 비우고 Sentinel에 다시 질의해 새 primary로 연결해야 합니다. 모든 BE/C++ 호스트에서 Sentinel 주소의 `26379`와 각 Redis 노드 주소의 `6379`에 접근할 수 있어야 합니다.
- `redis_server`의 현재 `redis_ip`/`redis_port` 등록값은 초기 primary 한 대의 주소이므로 failover 후 갱신되지 않습니다. 단일 HA 서비스에서는 세 노드를 각각 독립된 할당 대상으로 등록하지 말고, 기존 `redis_id`를 failover에도 유지되는 논리 서비스 식별자로 사용합니다. Sentinel 모드의 BE/C++은 행의 `redis_ip`/`redis_port`로 접속하지 않고 설정된 Sentinel seed에서 실제 primary 주소를 받아옵니다. 여러 Redis 서비스를 동적으로 선택해야 한다면 Sentinel seed와 master 이름을 저장할 수 있도록 등록 모델을 확장해야 합니다.
- 기존 `canvas:{canvasId}` 문서와 RediSearch 사용은 유지합니다. Sentinel failover는 샤딩을 제공하지 않으므로 Redis Cluster 전용 `MOVED`/slot 라우팅 로직을 추가할 필요는 없습니다. replica 읽기는 복제 지연으로 오래된 값을 반환할 수 있으므로 일관성 요구를 검토하지 않고 읽기 대상으로 사용하지 않습니다.

### 장애 후 데이터와 요청 처리

- Redis 복제는 비동기이므로 failover 직전 primary에서 확인된 일부 쓰기가 새 primary에 복제되지 않았을 수 있습니다([Redis replication 문서](https://redis.io/docs/latest/operate/oss_and_stack/management/replication/)). 애플리케이션은 캔버스 문서가 없거나 `canvas_info.is_cached`와 실제 Redis 키 상태가 다른 경우를 처리해야 하며, 기존 Elasticsearch 문서에서 복구할지 또는 사용자에게 재시도를 요청할지 동작을 정해야 합니다.
- 연결 오류에 대한 재시도는 요청 종류에 맞게 제한합니다. 완료 여부가 불명확한 비멱등 쓰기를 그대로 다시 보내 중복 반영하지 않도록 요청 식별자, 중복 방지 또는 상태 확인을 사용합니다.
- 배포 전 장애조치 검증에서 SQL 연결 풀의 복구, Redis primary 재탐색, 캔버스 문서/색인 접근, 진행 중 요청의 중복·유실 처리를 확인합니다. 장애조치 후에도 애플리케이션 설정이나 `canvas_info.redis_id`를 수동 변경하지 않고 서비스를 이어갈 수 있어야 합니다.

## 저장소 구조

```text
mssql/          SQL Server Compose, 스키마, 초기화·검색·정리 스크립트
redis/          Redis Stack Compose, ACL·RedisJSON·RediSearch 초기화 스크립트
elasticsearch/  Elasticsearch Compose, 사용자·인덱스 초기화 스크립트
tests/          저장소 통합 테스트
*.sh            통합 검색 및 정리 도구
```

## 라이선스

이 저장소는 Project Agora의 일부이며 [MIT License](LICENSE)를 따릅니다.
