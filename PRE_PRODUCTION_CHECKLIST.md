# 운영 전 정리 항목

이 문서는 DB 인프라 설정을 운영 환경에 적용하기 전에 완료할 작업을 기록합니다. 현재 작업에서는 사용자가 의도적으로 맞춘 테스트 비밀번호와 실제 `.env` 값은 변경하지 않았습니다.

## 이번에 반영한 설정

- [x] Redis 앱 계정 권한을 현재 BE와 failover 검증에서 사용하는 명령 및 키 패턴으로 제한했습니다.
- [x] Redis와 Sentinel에서 `protected-mode`를 활성화하고, 노드 바인딩을 기본적으로 사설 주소에 제한했습니다.
- [x] 다중 호스트 Redis와 Sentinel을 기본적으로 노드 사설 IP에 바인딩하도록 했습니다.
- [x] Sentinel 시작 때 persistent 설정의 ACL 경로와 Redis/Sentinel 인증 값을 현재 환경값으로 갱신합니다.
- [x] 현재 BE 호환성을 위해 Sentinel의 무인증 접근은 읽기 전용 토폴로지 조회로 제한하고, Sentinel 간 통신은 ACL 인증을 사용합니다.
- [x] RedisInsight 호스트 포트는 기본적으로 `127.0.0.1`에만 바인딩합니다.
- [x] Elasticsearch 캔버스 계정 권한에서 인덱스 관리 권한을 제거하고 문서 읽기·쓰기와 메타데이터 조회만 허용합니다.
- [x] SQL Server SA 예시 비밀번호와 생성 안내를 기본 복잡도 정책에 맞게 수정했습니다.

## 운영 전 필수 확인

- [ ] 테스트가 끝나면 서비스와 계정마다 별도 운영 비밀번호를 발급하고 각 DB/BE 설정에 같은 계정의 값을 맞춥니다. 이번 작업에서는 의도된 동일 테스트 값을 그대로 유지했습니다.
- [ ] 운영 비밀값은 권한이 제한된 비밀 저장소/배포 경로에서 주입하고, Compose 환경 변수와 컨테이너 inspect를 볼 수 있는 호스트 관리자 권한을 제한합니다. `.env`는 저장소에 커밋하지 않고 소유자만 읽을 수 있게 유지합니다.
- [ ] 실제 각 호스트에서 `MSSQL_NODE_BIND_IP`, `REDIS_NODE_ANNOUNCE_IP`, `REDIS_NODE_BIND_IP`, `REDIS_SENTINEL_BIND_IP`가 사설 인터페이스를 가리키는지 확인합니다. 방화벽/보안 그룹은 SQL 1433·5022, Redis 6379·26379, Elasticsearch 9200을 필요한 앱·클러스터·관리 호스트에만 허용해야 합니다.
- [ ] Redis/Sentinel 다중 호스트 트래픽은 현재 TLS 없이 동작합니다. 사설망 보호를 확인하거나 TLS를 적용하고 클라이언트 설정도 함께 변경합니다. Sentinel은 현 BE의 무인증 호환성을 위해 토폴로지 조회가 열려 있으므로, 완전한 Sentinel 인증이 필요하면 BE 클라이언트에 인증 지원을 추가하고 전환을 검증합니다.
- [ ] Elasticsearch는 HTTP TLS를 설정하지 않았습니다. 원격 BE 접속 전에 인증서를 배포하고 HTTPS 및 BE 인증서 검증을 설정합니다. 외부 접속이 필요하지 않다면 `ES_EXTERNAL_IP=127.0.0.1`을 유지합니다.
- [ ] SQL Server TLS 인증서를 구성하고 원격 관리 경로에서 `sqlcmd -C`의 인증서 신뢰 우회를 제거합니다. `-C`는 서버 인증서 검증을 생략합니다.
- [ ] SQL 앱 계정은 현재 DB 소유자(`dbo`)이고 `CHECK_POLICY`가 꺼져 있습니다. 기존 동작/테스트와 호환되도록 이번에는 유지했습니다. 운영 전 런타임 DML 계정과 스키마 마이그레이션 계정을 분리하고 권한 축소를 통합 테스트합니다.
- [ ] Elasticsearch 이미지는 `8.15.0`이며 Redis와 RedisInsight는 `latest`, SQL Server는 `2022-latest` 태그를 사용합니다. 유지보수 중인 Elasticsearch 버전과 고정된 이미지 태그/digest를 선정하고 업그레이드 호환성을 검증합니다.
- [ ] Elasticsearch와 로그 인덱스는 단일 노드이며 로그 인덱스 replica 수가 0입니다. 로그 복구 목표에 맞는 스냅샷 저장소, 보존 기간 및 복원 절차를 정합니다.
- [ ] 스테이징에서 저장소 CRUD, `./redis/test-failover.sh`, 장애 후 BE 재연결을 확인합니다. 이 Redis 스크립트는 한 호스트의 컨테이너 장애를 검증하므로 실제 호스트 장애와 네트워크 분할은 별도로 연습합니다.
- [ ] SQL Server 운영 HA는 Pacemaker quorum/fencing을 포함한 스테이징에서 계획 전환과 호스트 장애 전환을 검증합니다. Compose 설정 확인만으로 fencing이나 listener 동작이 검증되지는 않습니다.
- [ ] 백업에서 새 환경으로 복원하는 리허설을 수행하고, 복원된 SQL/Redis/Elasticsearch 데이터와 애플리케이션 로그를 확인합니다.

## 확인 기록

- `docker compose config -q`로 Redis 단일 노드·Sentinel·다중 호스트 노드, Elasticsearch, MS SQL Compose 설정을 정적으로 확인했습니다.
- 실제 컨테이너 기동, 네트워크 방화벽, TLS 연결, 스토리지 테스트와 장애 전환은 이 문서 작성 중 실행하지 않았습니다.
