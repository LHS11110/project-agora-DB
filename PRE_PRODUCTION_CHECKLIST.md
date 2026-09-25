# 운영 전 정리 항목

이 문서는 저장소에 반영된 구현과 대상 인프라에서 증명해야 하는 배포 작업을 구분합니다. 실제 운영 호스트와 계정 비밀값은 이 저장소에서 임의 변경하거나 접속 검증하지 않았습니다.

## 코드와 배포 템플릿에 반영 완료

- [x] SQL 앱 계정을 DB 소유자에서 분리했습니다. 초기화는 DB를 `sa` 소유로 두고 앱 로그인에는 `agora_runtime` 역할의 `dbo` 스키마 `SELECT/INSERT/UPDATE/DELETE`만 줍니다. `CHECK_POLICY=ON`이며 초기화 출력에서 역할과 `db_owner` 제외를 확인할 수 있습니다.
- [x] 저장소 통합 시험은 SQL 런타임 로그인으로 CRUD를 수행하고 DDL 권한이 거부되는지 확인하도록 바꿨습니다.
- [x] Spring JDBC는 SQL TLS와 서버 인증서 검증을 기본 사용합니다. C++ FreeTDS는 `DB_FREETDS_CONF`에서 `encryption=strict`, CA와 호스트명 검증을 요구하고, 개발용 예외는 `DB_TRUST_SERVER_CERTIFICATE=true`로 명시합니다.
- [x] SQL Compose는 `MSSQL_TLS_ENABLED=true`일 때 TLS 인증서, 키, TLS 1.2, 강제 암호화를 설정하는 시작 경로를 제공합니다. `init-mssql.sh`는 기본적으로 `sqlcmd -C`를 쓰지 않습니다.
- [x] Spring과 C++은 Elasticsearch HTTPS를 사용하고 CA/기본 trust store로 인증서를 검증할 수 있습니다. Sentinel 인증 전용 사용자/비밀번호도 양쪽 클라이언트, Redis 초기화, HA 운영·failover 시험 도구에 연결했습니다.
- [x] Redis 8.6.7, Redis Insight 3.8.0, Elasticsearch 8.19.22, SQL Server 2022 CU26의 고정 버전 이미지 태그를 사용합니다. Elasticsearch 로그는 쓰기 alias, 1일/10GB rollover, 기본 90일 ILM 삭제 정책을 사용합니다.
- [x] Elasticsearch 초기화는 매일 SLM snapshot과 35일 보존을 설정합니다. Elasticsearch snapshot, SQL backup/restore, Redis primary RDB backup/restore 스크립트가 준비되어 있습니다. 복원 스크립트는 명시적인 환경변수 확인을 요구하고 기존 SQL DB를 덮어쓰지 않습니다.
- [x] Spring은 `/run/secrets/` config tree를 읽고 C++은 비밀번호 변수의 `*_FILE` 경로를 읽을 수 있습니다. 기존 환경변수 배포 방식도 유지됩니다.

## 대상 환경에서 실행하고 결과를 기록할 항목

- [ ] 기존 테스트 비밀번호를 서비스·계정별 운영 비밀값으로 교체하고 DB와 BE 값을 맞춥니다. 비밀 관리자에서 주입하고 `.env` 파일은 Git에 넣지 않으며 소유자 전용 권한으로 유지합니다. Compose inspect 권한도 제한합니다.
- [ ] 실제 호스트의 `MSSQL_NODE_BIND_IP`, `REDIS_NODE_ANNOUNCE_IP`, `REDIS_NODE_BIND_IP`, `REDIS_SENTINEL_BIND_IP`가 사설 인터페이스인지 확인합니다. 방화벽/보안 그룹은 SQL 1433·5022, Redis 6379·26379, Elasticsearch 9200을 필요한 앱·클러스터·관리 호스트에만 허용합니다.
- [ ] 모든 Sentinel에 전용 읽기 계정 환경변수를 설정하고 C++/Spring의 Sentinel 주소 조회를 확인합니다. Redis/Sentinel TLS 대신 사설망 격리를 사용할 경우 실제 경로에서 평문 트래픽이 인터넷이나 신뢰되지 않는 네트워크를 통과하지 않는지 검증합니다.
- [ ] CA 서명 Elasticsearch 인증서·키를 배포하고 `ES_HTTP_TLS_ENABLED=true`, BE `ES_SCHEME=https`, `ES_CA_CERT`를 설정해 인증서 체인과 호스트명이 확인되는지 검사합니다. 원격 접속이 없으면 ES 포트는 loopback에 둡니다.
- [ ] SQL Server 각 노드에 listener와 노드 이름을 포함한 인증서를 배포하고 `MSSQL_TLS_ENABLED=true`로 재기동합니다. Spring과 C++이 CA와 호스트명을 검증하는지 확인합니다. 원격 관리자 `sqlcmd` 명령에는 `-C`를 사용하지 않습니다.
- [ ] 운영 SQL DB에서 `./mssql/init-mssql.sh`를 실행해 기존 계정의 소유자 권한을 제거하고, `python3 tests/test_storages.py`로 DML 성공 및 DDL 거부를 검증합니다.
- [ ] Elasticsearch 8.15 데이터 복사본을 8.19.22로 업그레이드해 인덱스, 문서, 보안 계정, ILM/SLM을 확인합니다. 8.x에서 9.x로 갈 때는 최신 8.19가 선행되어야 하므로 9.x 이미지로 기존 볼륨을 바로 연결하지 않습니다.
- [ ] Elasticsearch snapshot 호스트 경로를 별도 내구성 저장소에 연결하고 UID 1000 쓰기 권한을 확인합니다. SLM의 첫 snapshot 성공, 보존 정책, 새 ES 환경에서의 실제 복원 결과를 기록합니다. 기존 구체 로그 인덱스는 앱을 멈춘 상태에서 snapshot 후 `./elasticsearch/migrate-log-index-to-ilm.sh`로 옮깁니다.
- [ ] 스테이징에서 SQL·Redis·Elasticsearch 저장소 CRUD, `./redis/test-failover.sh`, 장애 후 BE 재연결 및 로그 기록을 확인합니다. Redis 컨테이너 장애 외에 실제 호스트 장애와 네트워크 분할도 연습합니다.
- [ ] Pacemaker quorum/fencing을 갖춘 SQL AG 스테이징에서 계획 전환과 호스트 장애 전환을 확인합니다. Compose만으로 quorum, fencing, listener 동작을 증명할 수 없습니다.
- [ ] `./mssql/backup-database.sh`, `./redis/snapshot-ha.sh`, `./elasticsearch/snapshot-elasticsearch.sh`로 만든 데이터와 애플리케이션 로그를 새 환경에 복원하고 실제 BE 읽기·쓰기까지 검증합니다.

## 현재 확인 범위

- 현재 개인 `.env` 파일은 모두 Git에서 제외되어 있고 권한 `0600`입니다. 다만 BE의 Sentinel seed 설정에 전용 `REDIS_SENTINEL_USER`/`REDIS_SENTINEL_PASSWORD`가 없고 Redis `.env`에도 해당 자격 증명이 없습니다. Elasticsearch/SQL TLS 활성화 변수도 설정되지 않아 이 개인 개발 설정을 운영 설정으로 간주하면 안 됩니다.
- 2026-09-25 검증: C++ CTest 2/2 통과, Spring 테스트 67개 중 66개 통과·1개 건너뜀(실제 Elasticsearch CRUD 테스트는 `localhost:9200` 데이터 변경을 포함하므로 실행하지 않음). C++/Spring 빌드, 셸 구문, Compose 정적 설정도 통과했습니다.
- 실제 SQL/Redis/Elasticsearch 저장소 CRUD, Redis 컨테이너 failover, 백업 복원은 운영 데이터 변경을 일으킬 수 있어 이번 실행에서는 하지 않았습니다.
- 운영 인증서, 실제 방화벽, 기존 Elasticsearch 데이터 업그레이드, 운영 SQL 권한 변경, 스테이징 장애 전환, 실제 백업 복원은 수행하지 않았습니다.
