# DB 호스트 설정 자동화

`ops/` 스크립트는 이 저장소의 DB 요구사항에 맞춰 환경 파일 준비, 사전 검사, BE 연결 설정 반영, 서비스 기동, 백업 예약을 수행합니다. 비밀번호와 인증서 개인 키는 출력하지 않습니다. 운영 주소·인증서·마운트 지점은 각 환경에 맞게 제공해야 하므로 스크립트가 임의로 만들지 않습니다.

## 개발 환경

저장소 루트에서 실행합니다.

```bash
python3 ops/configure-db.py prepare
python3 ops/configure-db.py validate --profile development
python3 ops/configure-db.py deploy-local
```

`prepare`는 누락된 `.env`를 `.env.example`에서 만들고 placeholder 비밀번호를 서로 다른 난수로 바꿉니다. 이미 설정된 비밀번호는 유지합니다. 파일 권한은 `0600`으로 설정하며 인증서는 발급하지 않습니다. `deploy-local`은 단일 노드 개발 서비스를 올리고 health check 및 초기화를 수행합니다.

## 운영 사전 검사

먼저 `.env`와 난수 자격 증명을 준비하고, 발급받은 서버 인증서·키·CA를 각 인증서 디렉터리에 둡니다. 실제 백업 저장소를 마운트한 다음 아래 명령으로 TLS, 사설 주소, ES snapshot 경로를 서비스 `.env`에 기록할 수 있습니다.

```bash
python3 ops/configure-db.py prepare
python3 ops/configure-db.py configure-production \
  --sql-host sql-ag.internal --sql-node-hostname agora-sql-01 --sql-bind-ip 10.20.0.11 \
  --es-host elasticsearch.internal --es-bind-ip 10.20.0.30 \
  --redis-primary-ip 10.20.0.21 \
  --redis-sentinels 10.20.0.21:26379,10.20.0.22:26379,10.20.0.23:26379 \
  --sql-cert-dir /etc/project-agora/mssql-tls \
  --es-cert-dir /etc/project-agora/elasticsearch-tls \
  --redis-cert-dir /etc/project-agora/redis-tls \
  --backup-root /mnt/agora-backups
python3 ops/configure-db.py prepare-storage
```

SQL/Elasticsearch Compose 포트 바인딩에는 사설 IPv4 주소를 지정합니다. SQL 인증서는 SQL AG listener와 해당 호스트 SQL Server 이름 모두를 SAN에 포함해야 합니다. Elasticsearch 인증서는 `--es-host`를 포함해야 합니다. 명령은 인증서 체인·키 짝·만료일·SAN과 사설 주소 및 실제 백업 마운트를 먼저 검사하고, 통과하면 서비스 TLS·주소·snapshot 설정을 갱신합니다. 기본 snapshot 디렉터리는 `/mnt/agora-backups/elasticsearch-snapshots`입니다.

각 서비스 `.env`에는 다음 보안 설정이 적용됩니다.

- `mssql/.env`: `MSSQL_TLS_ENABLED=true`, `DB_TRUST_SERVER_CERTIFICATE=false`, 노드의 사설 `MSSQL_EXTERNAL_IP`, 관리용 `MSSQL_MANAGEMENT_HOST`/`MSSQL_MANAGEMENT_PORT`, CA가 서명한 `tls/server.crt`, `tls/server.key`, `tls/ca.crt`
- `elasticsearch/.env`: `ES_HTTP_TLS_ENABLED=true`, `ES_SCHEME=https`, 사설 `ES_EXTERNAL_IP`, CA가 서명한 `certs/http.crt`, `certs/http.key`, `certs/ca.crt`; `ES_CA_CERT`는 DB 관리 도구가 읽을 절대 호스트 경로, `ES_SNAPSHOT_HOST_DIR`는 별도 내구성 저장소 경로
- `redis/.env`: `REDIS_TLS_ENABLED=true`, 전용 `REDIS_SENTINEL_USER`/`REDIS_SENTINEL_PASSWORD`, TLS 서버 인증서·키·CA, `REDIS_TLS_CA_CERT_HOST`, 세 Sentinel seed를 설정하고 `REDIS_EXTERNAL_IP`를 초기 primary의 사설 주소로 지정

`configure-production` 실행 후 listener/서비스 주소와 Sentinel seed 3개를 다시 검사할 수 있습니다.

```bash
python3 ops/configure-db.py validate --profile production \
  --sql-host sql-ag.internal \
  --es-host elasticsearch.internal \
  --redis-sentinels 10.20.0.21:26379,10.20.0.22:26379,10.20.0.23:26379 \
  --backup-root /mnt/agora-backups
```

이 검사는 비밀번호 강도·중복, 사설 주소, Compose 문법, SQL/Elasticsearch/Redis 인증서 체인·만료일·SAN, ES snapshot 디렉터리가 실제 백업 마운트 안에 있는지 확인합니다. Redis와 Sentinel은 TLS를 사용하고 평문 listener를 비활성화해야 합니다. DNS 이름은 검사하는 호스트에서 사설 IP로 해석되어야 합니다. 이 설정 검사는 네트워크 경로나 방화벽을 대체하지 않으므로 배포 전 각 BE/복제 호스트에서 Sentinel과 Redis 주소로 가는 route와 ACL/firewall을 확인해 트래픽이 신뢰되지 않는 네트워크를 통과하지 않도록 하세요. 현재 Compose 템플릿은 서비스별 `.env`를 읽으므로 배포 호스트에서 안전하게 준비하고 `0600` 권한을 유지하세요. 외부 비밀 관리자를 쓰는 경우 이 파일을 안전하게 생성·주입하는 방법은 조직의 배포 도구에 연결해야 합니다.

## BE 설정 동기화

인증서 검증을 마친 뒤 기존 BE `.env`에 DB 관련 설정만 반영할 수 있습니다. 기존의 다른 BE 설정은 보존됩니다. `--es-ca-cert`는 DB 호스트에서 찾는 파일이 아니라 BE 실행 컨테이너 안에서 사용할 절대 경로입니다.

```bash
python3 ops/configure-db.py sync-backend \
  --backend-env ../project-agora-BE/.env \
  --db-host sql-ag-listener.internal --db-port 1433 --multi-subnet \
  --db-freetds-conf /etc/freetds/freetds.conf \
  --es-host elasticsearch.internal --es-port 9200 \
  --es-ca-cert /run/secrets/elasticsearch/ca.crt \
  --redis-ca-cert /run/secrets/redis/ca.crt \
  --redis-sentinels 10.20.0.21:26379,10.20.0.22:26379,10.20.0.23:26379
```

동기화는 DB의 SQL·Redis·Elasticsearch 사용자 비밀번호도 BE `.env`에 기록하므로, 생성된 파일 권한은 `0600`입니다. `DB_FREETDS_CONF`는 C++이 사용할 FreeTDS 설정 파일 경로입니다. 해당 파일은 `encryption = strict`, CA 파일, `check certificate hostname = yes`를 설정해야 합니다. 호스트의 `sqlcmd`와 Spring JVM 기본 trust store에도 SQL 발급 CA가 있어야 합니다. BE 배포가 secret/config tree를 사용한다면 BE 환경변수 주입 규칙에 맞춰 동일한 값을 전달하세요.

`--es-ca-cert`와 `--redis-ca-cert`는 설정 검사를 실행하는 DB 호스트가 아니라 실제 BE 런타임 안에서 접근 가능한 경로여야 합니다. 인증서 파일뿐 아니라 모든 상위 디렉터리도 C++/Spring 실행 사용자에게 읽기·탐색 가능해야 합니다. 개발 인증서가 권한이 제한된 DB 디렉터리에 있으면 CA 공개 인증서만 BE가 읽을 수 있는 경로로 복사하고, 개인 키가 있는 디렉터리 권한은 넓히지 마세요.

## 다중 호스트 노드 기동

### SQL Server 노드

각 SQL 호스트에서 인증서와 `.env`를 준비한 뒤 호스트별 값을 지정합니다.

```bash
MSSQL_NODE_HOSTNAME=agora-sql-01 \
MSSQL_NODE_BIND_IP=10.20.0.11 \
MSSQL_NODE_PID=Standard \
MSSQL_NODE_TLS_CERTS_DIR=/etc/project-agora/mssql-tls \
python3 ops/configure-db.py deploy-sql-ag-node
```

복제 노드는 고유한 `MSSQL_NODE_HOSTNAME`, 사설 `MSSQL_NODE_BIND_IP`와 적합한 SQL Server 라이선스를 사용합니다. 스크립트는 SQL 컨테이너 한 대만 시작합니다. Availability Group, AG listener, Pacemaker quorum/fencing, 인증서 배포, 방화벽은 Linux 호스트에서 별도로 구성해야 합니다. Basic Availability Group 라이선스·복제본 제약은 [SQL Server AG 절차](../mssql/cluster/README.md)를 따릅니다.

### Redis/Sentinel 노드

세 호스트 각각에 `.env`와 동일한 앱/Sentinel ACL 비밀번호를 준비합니다. `REDIS_SENTINEL_MASTER_HOST`는 모든 Sentinel에서 동일한 초기 primary 주소여야 합니다.

초기 primary:

```bash
REDIS_COMPOSE_PROJECT=agora-redis-01 \
REDIS_NODE_ROLE=primary REDIS_NODE_HOSTNAME=agora-redis-01 \
REDIS_NODE_ANNOUNCE_IP=10.20.0.21 REDIS_NODE_BIND_IP=10.20.0.21 \
REDIS_SENTINEL_MASTER_HOST=10.20.0.21 \
python3 ops/configure-db.py deploy-redis-ha-node
```

replica는 별도의 프로젝트·호스트·사설 IP를 쓰고 `REDIS_NODE_ROLE=replica`, `REDIS_NODE_PRIMARY_HOST=10.20.0.21`을 지정합니다. 각 호스트의 `REDIS_NODE_BIND_IP`와 `REDIS_SENTINEL_BIND_IP`는 `REDIS_NODE_ANNOUNCE_IP`와 같은 사설 인터페이스 주소여야 합니다. 이 스크립트는 해당 호스트에 Redis와 Sentinel을 기동하고 ACL/초기화를 수행합니다. 노드 3개를 서로 다른 호스트에 배치한 뒤 방화벽, 복제, Sentinel discovery와 실제 BE/C++ 재연결을 시험해야 합니다.

## 백업과 예약

먼저 별도 내구성 저장소를 실제 마운트하고, Elasticsearch snapshot 경로를 그 안에 둡니다. SQL/Redis 백업 파일과 manifest는 실행별 하위 폴더에 저장됩니다.

```bash
AGORA_BACKUP_ROOT=/mnt/agora-backups ./ops/backup-all.sh
sudo ./ops/install-backup-timer.sh /mnt/agora-backups
```

`backup-all.sh`는 인자로 지정한 경로가 실제 마운트 지점이 아니면 중단합니다. SQL은 현재 standalone 인스턴스 또는 이 호스트의 단일 AG 노드를 자동 선택하고 `VERIFYONLY`를 실행합니다. Redis는 Sentinel primary의 RDB를 검사합니다. Elasticsearch는 설정한 외부 snapshot repository에 snapshot을 만듭니다. 설치 명령은 매일 03:15 UTC systemd timer를 켭니다. 백업 성공 알림, 외부 복제, 저장소 용량·수명주기 정책과 실제 새 환경 복원 시험은 운영자가 연결해야 합니다.

## 남는 인프라 작업

스크립트만으로 인증기관에서 운영 인증서를 발급하거나, 클라우드 방화벽을 열거나, Pacemaker quorum/fencing을 증명할 수는 없습니다. 다중 호스트 장애 전환 및 BE/C++ 재연결, 새 환경 복원과 저장소 수명주기 정책은 [운영 전 체크리스트](../PRE_PRODUCTION_CHECKLIST.md)의 대상 환경 항목을 완료하고 기록해야 합니다.
