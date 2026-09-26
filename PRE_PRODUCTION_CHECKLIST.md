# 운영 전 정리 항목

이 문서는 저장소에 반영된 구현과 대상 인프라에서 증명해야 하는 배포 작업을 구분합니다. 아래의 로컬 실행 상태 확인은 현재 개발 호스트의 스냅샷이며 운영 환경의 증거로 간주하지 않습니다.

## 코드와 배포 템플릿에 반영 완료

- [x] `ops/configure-db.py`로 환경 파일·비밀번호 준비, 개발/운영 사전 검사, 기존 BE `.env`의 DB 연결 설정 동기화, 개발 서비스 및 SQL/Redis HA 노드 기동을 자동화했습니다. `ops/backup-all.sh`는 내구성 저장소 마운트를 확인한 뒤 SQL·Redis·Elasticsearch 백업을 모으고, `ops/install-backup-timer.sh`는 매일 systemd 예약을 설치합니다.
- [x] SQL 앱 계정을 DB 소유자에서 분리했습니다. 초기화는 DB를 `sa` 소유로 두고 앱 로그인에는 `agora_runtime` 역할의 `dbo` 스키마 `SELECT/INSERT/UPDATE/DELETE`만 줍니다. `CHECK_POLICY=ON`이며 초기화 출력에서 역할과 `db_owner` 제외를 확인할 수 있습니다.
- [x] 저장소 통합 시험은 SQL 런타임 로그인으로 CRUD를 수행하고 DDL 권한이 거부되는지 확인하도록 바꿨습니다.
- [x] Spring JDBC는 SQL TLS와 서버 인증서 검증을 기본 사용합니다. C++ FreeTDS는 `DB_FREETDS_CONF`에서 `encryption=strict`, CA와 호스트명 검증을 요구하고, 개발용 예외는 `DB_TRUST_SERVER_CERTIFICATE=true`로 명시합니다.
- [x] SQL Compose는 `MSSQL_TLS_ENABLED=true`일 때 TLS 인증서, 키, TLS 1.2, 강제 암호화를 설정하는 시작 경로를 제공합니다. `init-mssql.sh`는 기본적으로 `sqlcmd -C`를 쓰지 않습니다.
- [x] Spring과 C++은 Elasticsearch HTTPS를 사용하고 CA/기본 trust store로 인증서를 검증할 수 있습니다. Sentinel 인증 전용 사용자/비밀번호도 양쪽 클라이언트, Redis 초기화, HA 운영·failover 시험 도구에 연결했습니다.
- [x] Redis 8.6.7, Redis Insight 3.8.0, Elasticsearch 8.19.22, SQL Server 2022 CU27의 고정 버전 이미지 태그를 사용합니다. Elasticsearch 로그는 쓰기 alias, 1일/10GB rollover, 기본 90일 ILM 삭제 정책을 사용합니다.
- [x] Elasticsearch 초기화는 매일 SLM snapshot과 35일 보존을 설정합니다. Elasticsearch snapshot, SQL backup/restore, Redis primary RDB backup/restore 스크립트가 준비되어 있습니다. 복원 스크립트는 명시적인 환경변수 확인을 요구하고 기존 SQL DB를 덮어쓰지 않습니다.
- [x] Spring은 `/run/secrets/` config tree를 읽고 C++은 비밀번호 변수의 `*_FILE` 경로를 읽을 수 있습니다. 기존 환경변수 배포 방식도 유지됩니다.

## 대상 환경에서 실행하고 결과를 기록할 항목

- [ ] 기존 테스트 비밀번호를 서비스·계정별 운영 비밀값으로 교체하고 DB와 BE 값을 맞춥니다. 비밀 관리자에서 주입하고 `.env` 파일은 Git에 넣지 않으며 소유자 전용 권한으로 유지합니다. Compose inspect 권한도 제한합니다.
- [ ] 실제 호스트의 `MSSQL_NODE_BIND_IP`, `REDIS_NODE_ANNOUNCE_IP`, `REDIS_NODE_BIND_IP`, `REDIS_SENTINEL_BIND_IP`가 사설 인터페이스인지 확인합니다. 방화벽/보안 그룹은 SQL 1433·5022, Redis 6379·26379, Elasticsearch 9200을 필요한 앱·클러스터·관리 호스트에만 허용합니다.
- [x] 개발 Docker HA의 3개 Sentinel에 전용 읽기 전용 계정을 설정하고 C++/Spring이 TLS로 세 주소를 조회해 같은 primary를 찾는 것을 확인했습니다. Redis와 Sentinel은 TLS listener만 열고 평문 probe가 거부되며, 컨테이너 네트워크는 internal bridge입니다.
- [ ] 운영 BE/복제 호스트 각각에서 route와 방화벽을 확인해 Sentinel·Redis 평문이 인터넷이나 신뢰되지 않는 네트워크를 통과하지 않고, 사설망 경로와 TLS가 모두 적용되는지 검증합니다.
- [ ] CA 서명 Elasticsearch 인증서·키를 배포하고 `ES_HTTP_TLS_ENABLED=true`, BE `ES_SCHEME=https`, `ES_CA_CERT`를 설정해 인증서 체인과 호스트명이 확인되는지 검사합니다. 원격 접속이 없으면 ES 포트는 loopback에 둡니다.
- [ ] SQL Server 각 노드에 listener와 노드 이름을 포함한 인증서를 배포하고 `MSSQL_TLS_ENABLED=true`로 재기동합니다. Spring과 C++이 CA와 호스트명을 검증하는지 확인합니다. 원격 관리자 `sqlcmd` 명령에는 `-C`를 사용하지 않습니다.
- [ ] 운영 SQL DB에서 `./mssql/init-mssql.sh`를 실행해 기존 계정의 소유자 권한을 제거하고, `python3 tests/test_storages.py`로 DML 성공 및 DDL 거부를 검증합니다.
- [ ] Elasticsearch 8.15 데이터 복사본을 8.19.22로 업그레이드해 인덱스, 문서, 보안 계정, ILM/SLM을 확인합니다. 8.x에서 9.x로 갈 때는 최신 8.19가 선행되어야 하므로 9.x 이미지로 기존 볼륨을 바로 연결하지 않습니다.
- [ ] Elasticsearch snapshot 호스트 경로를 별도 내구성 저장소에 연결하고 UID 1000 쓰기 권한을 확인합니다. SLM의 첫 snapshot 성공, 보존 정책, 새 ES 환경에서의 실제 복원 결과를 기록합니다. 기존 구체 로그 인덱스는 앱을 멈춘 상태에서 snapshot 후 `./elasticsearch/migrate-log-index-to-ilm.sh`로 옮깁니다.
- [ ] 스테이징에서 SQL·Redis·Elasticsearch 저장소 CRUD, `./redis/test-failover.sh`, 장애 후 BE 재연결 및 로그 기록을 확인합니다. Redis 컨테이너 장애 외에 실제 호스트 장애와 네트워크 분할도 연습합니다.
- [ ] Pacemaker quorum/fencing을 갖춘 SQL AG 스테이징에서 계획 전환과 호스트 장애 전환을 확인합니다. Compose만으로 quorum, fencing, listener 동작을 증명할 수 없습니다.
- [ ] `./mssql/backup-database.sh`, `./redis/snapshot-ha.sh`, `./elasticsearch/snapshot-elasticsearch.sh`로 만든 데이터와 애플리케이션 로그를 새 환경에 복원하고 실제 BE 읽기·쓰기까지 검증합니다.

## 현재 확인 범위

- 2026-09-26 코드 검증: C++를 새 `/tmp` 빌드 디렉터리에 구성·컴파일했고 CTest 2/2 통과했습니다. Spring Gradle 테스트는 68개 중 67개 통과, 1개 건너뜀, 실패 0개였습니다. 건너뛴 것은 고정 문서 ID를 변경하는 Elasticsearch 실연동 테스트입니다.
- 2026-09-26 Docker 저장소 통합 검사: `tests/test_storages.py` 27/27 통과했습니다. 앱과 같은 세 Sentinel seed를 호스트에서 조회한 뒤 SQL 런타임 계정의 DML/DDL 권한, Elasticsearch HTTPS CA 검증, Redis ACL·JSON·검색·키 범위 제한을 확인했습니다. `init-redis-sentinel.sh`의 ACL·검색 인덱스·SQL endpoint 초기화도 통과했습니다. 로컬 SQL은 개발용 자체 서명 인증서라 저장소 검사·초기화와 개발 BE 실기동에서 `DB_TRUST_SERVER_CERTIFICATE=true`를 사용합니다. 운영에서는 SQL CA 검증 설정이 필요합니다.
- 2026-09-26 Redis HA 로컬 검사: Redis 8.6.7 primary 1대, replica 2대, Sentinel 3대를 Docker bridge network에서 기동했습니다. Sentinel 컨테이너를 시작 스크립트 변경 후 순차 재기동하고, `redis/test-failover.sh`에서 primary 중단, replica 승격, 세 Sentinel의 새 주소 발견, 기존 primary 복귀를 통과했습니다. Sentinel 읽기 전용 ACL을 통한 실제 호스트 클라이언트의 discovery/CRUD도 통과했습니다. 독립 RDB snapshot 생성과 무결성 검사를 통과했습니다. 이는 단일 호스트 테스트이며 호스트 장애 내성을 증명하지 않습니다.
- 2026-09-26 Redis 데이터 이관: 기존 단일 노드 RDB를 named volume에 복원해 문서와 `idx:canvas` 인덱스를 확인한 뒤 AOF를 활성화했습니다. 이 과정에서 중지된 컨테이너 대상 `docker cp`가 mounted volume에 반영되지 않을 수 있음을 확인해 `redis/import-rdb-into-ha-volume.sh`를 추가하고 운영 안내를 수정했습니다.
- 2026-09-26 SQL 백업·복원: `backup-database.sh`가 CHECKSUM 백업과 `VERIFYONLY`를 완료했습니다. 격리된 새 SQL Server 컨테이너에 실제 복원했고 테이블 5개를 확인한 뒤 임시 컨테이너와 볼륨을 제거했습니다.
- 2026-09-26 Elasticsearch: 로컬 Elasticsearch 8.15 데이터를 8.19.22로 올리고 HTTPS를 로컬 CA로 검증했습니다. 수동 snapshot 생성과 별도 8.19.22 컨테이너에서 `canvas` 복원을 확인했습니다. Snapshot 호스트 디렉터리는 로컬 테스트 경로입니다.
- 2026-09-26 Redis TLS 경로: HA Docker bridge는 `internal=true`이며 Redis와 Sentinel 모두 TLS listener만 사용하고 호스트 포트를 publish하지 않습니다. 각 Redis/Sentinel 주소의 인증서 SAN·CA를 확인했고, 평문 접속 probe는 거부됐으며 bridge 주소는 로컬 Docker 경로로 라우팅됩니다.
- 2026-09-26 백엔드 실기동: Spring과 C++을 `steam` 사용자로 loopback에 기동했습니다. 두 `/health`가 HTTP 200이고 C++ 서버가 SQL `cpp_server`에 active로 등록됐습니다. Spring의 TLS Sentinel smoke test는 세 Sentinel 모두에서 같은 primary를 찾았고, C++ `RedisClient`도 Sentinel 조회 후 TLS Redis `PING`에 성공했습니다. C++ 로그 5건의 Elasticsearch 적재를 확인했습니다.
- 2026-09-26 C++ DB 연결 수정: FreeTDS 텍스트·정수 입력 RPC 인자의 `maxlen`/`datalen` 값이 잘못되어 SQL RPC가 실패하던 문제를 수정했습니다. 실제 정수 RPC 검사와 SQL Server의 C++ 서버 등록·기동으로 확인했습니다.
- 현재 개발 Docker 상태: SQL Server 2022 CU27 단일 인스턴스, Elasticsearch 8.19.22, Redis Sentinel primary/replica 3노드와 Sentinel 3대, Redis Insight가 실행 중입니다. 기존 단일 Redis 컨테이너와 데이터 볼륨은 중지 상태로 보존했습니다. SQL 및 Elasticsearch 복원 검증용 임시 컨테이너와 볼륨은 정리했습니다.
- 운영 비밀값 교체, CA 발급기관 인증서와 SQL TLS, 운영 호스트 방화벽/사설망 및 route 확인, 외부 내구성 저장소와 예약 snapshot 복구, 실제 BE 요청을 유지한 Redis 장애 전환, 다중 호스트 장애 시험, Pacemaker quorum/fencing을 갖춘 SQL AG 검증은 아직 남아 있습니다. 현재 로컬 컨테이너만으로는 이 운영 환경 조건을 증명할 수 없습니다.
