# DB TLS 초기 설정

SQL Server·Elasticsearch·Redis/Sentinel·Redis Insight는 기본적으로 TLS를 사용합니다. 서버 인증서·개인 키·공개 CA는 직접 준비합니다. `prepare`는 환경 파일과 무작위 비밀번호를 준비하며 인증서는 생성하지 않습니다.

전체 앱은 [clone부터 실행까지 안내](../project-agora-FE/docs/TLS_SETUP.md)를 따르세요. DB 설정만 먼저 준비하려면 다음을 실행합니다.

```bash
python3 ops/configure-db.py prepare --tls-dir /path/to/certificates
```

인증서 묶음에서 다음 디렉터리를 사용합니다.

| 서비스 | 직접 넣을 파일 |
| --- | --- |
| SQL Server | `mssql/server.crt`, `mssql/server.key`, `mssql/ca.crt` |
| Redis/Sentinel | `redis/server.crt`, `redis/server.key`, `redis/ca.crt` |
| Elasticsearch | `elasticsearch/http.crt`, `elasticsearch/http.key`, `elasticsearch/ca.crt` |
| Redis Insight | `internal/redis-insight/fullchain.pem`, `privkey.pem`, `ca.pem` |

`--tls-dir`를 생략하면 각 프로젝트의 `.env.example`에 있는 인증서 디렉터리를 사용합니다. 기존 비밀번호와 사용자 지정 설정을 보존하고 TLS와 인증서 검증은 활성화합니다. 인증서 SAN과 키 형식은 전체 안내를 참고하세요.

```bash
python3 ops/configure-db.py prepare-storage
python3 ops/configure-db.py validate --profile development
docker compose up -d --wait --wait-timeout 240
```

SQL Server·Redis Insight의 TLS 볼륨은 DB Compose가 준비하므로 BE를 먼저 실행할 필요가 없습니다. 운영 HA 구성은 [운영 안내](ops/README.md)를 따릅니다.
