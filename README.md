# project-agora-DB

아고라(Agora) 프로젝트의 데이터베이스 인프라 구축 및 스키마/인덱스 설정 가이드입니다.

- **Elasticsearch**: 캔버스 및 아이템 검색/저장용 검색 엔진
- **Redis Stack**: RedisJSON 및 RediSearch를 이용한 인메모리 캔버스 캐시 및 실시간 조회
- **MS SQL**: 캔버스 캐시 상태 확인 및 영구 메타데이터 관리

---

## 1. 컨테이너 일괄 실행 (Docker Compose)

```bash
docker compose up -d
```

### 컨테이너 및 포트 구성
| 서비스 | 컨테이너 이름 | 포트 | 용도 |
| :--- | :--- | :--- | :--- |
| **Elasticsearch** | `agora-elasticsearch` | `9200`, `9300` | REST API 및 클러스터 통신 |
| **Redis Stack** | `agora-redis-stack` | `6379`, `8001` | Redis 서버 (6379) / RedisInsight 웹 UI (8001) |
| **MS SQL 2022** | `agora-mssql` | `1433` | SQL Server DB |

---

## 2. 초기화 및 테이블/인덱스 생성

### (1) MS SQL 테이블 생성
`init-mssql.sql` 스크립트를 컨테이너 내부의 `sqlcmd`로 실행합니다.
```bash
docker exec -i agora-mssql /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P 'AgoraStrong@Passw0rd' -C < init-mssql.sql
```

### (2) Elasticsearch 인덱스 및 매핑 생성
```bash
./init-elasticsearch.sh
```

### (3) Redis Stack 인덱스 생성 및 샘플 데이터 등록
컨테이너 내부 `redis-cli`를 통해 실행:
```bash
docker exec -i agora-redis-stack redis-cli < init-redis.sh
```
(로컬에 `redis-cli`가 설치된 경우 바로 `./init-redis.sh` 실행 가능)