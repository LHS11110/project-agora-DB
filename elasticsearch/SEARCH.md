# 한국어·의미 검색

캔버스 검색은 원본 `canvas` 문서와 별도 `canvas-search` 메타데이터 projection을 사용합니다. 검색 인덱스 생성은 원본 문서나 객체 스냅샷을 삭제하지 않습니다. 기존 캔버스 목록 API의 이름 검색에 적용되며 빈 검색어의 목록 동작은 유지됩니다.

| 경로 | 역할 |
|---|---|
| Nori `mixed` | 복합어와 구성 형태소를 함께 색인, 조사·어미 제거 |
| Nori `discard` + `synonym_graph` | 검색 시 한국어·영어 동의어 및 여러 단어 확장 |
| 별도 `typo` 필드 | 표준 tokenizer로 오타를 형태소 분할하지 않고, 동의어 그래프와 분리하여 편집거리 `AUTO:3,6`, 후보 25개 제한으로 오타 보정 |
| `compact` 필드 | 제목의 공백을 제거하여 띄어쓰기 차이 보정 |
| E5 + `int8_hnsw` | 384차원 cosine 근사 k-NN 의미 검색 |
| Spring 가중 RRF | Nori 키워드(가중치 2), 원본 키워드(1), 벡터(1)의 순위를 합산 |

정확한 제목·구문 일치에 높은 BM25 boost를 줍니다. 의미 검색은 기본 cosine 0.80 이상, 후보 500개, 최종 결과 최대 100개입니다. RRF는 애플리케이션에서 계산하므로 Elasticsearch의 유료 RRF 또는 inference 기능이 필요하지 않습니다. 근사 검색과 모델 유사도는 모든 오타나 의미 일치를 보장하지 않으며 실제 검색어로 기준값을 조정해야 합니다.

## 모델과 데이터 흐름

BE `search` 컨테이너는 `intfloat/multilingual-e5-small`의 고정 revision `614241f622f53c4eeff9890bdc4f31cfecc418b3` ONNX 모델을 CPU로 실행합니다. 이미지 빌드 시 Hugging Face의 공개 모델 파일을 HTTPS로 다운로드합니다. 런타임에는 외부 API를 호출하지 않고 문서나 검색어를 외부에 전송하지 않습니다. MIT 모델 카드가 이미지 `/models/e5/MODEL_CARD.md`에 포함됩니다.

문서는 `passage: `, 검색어는 언어와 관계없이 `query: ` 접두어를 사용합니다. attention-mask 평균 pooling과 L2 정규화를 수행합니다. 입력은 최대 8192자, 토큰은 512개로 잘립니다. 모델 실행은 직렬화하며 문서 배치 4개, 요청 배치 최대 8개, CPU 스레드 기본 2개입니다. 기본 컨테이너 제한은 CPU 2개, 메모리 2 GiB이며 긴 문서·처리량은 배포 자원에서 측정해야 합니다.

```text
원본 ES canvas → Wall storage-broker → BE E5 worker
                                        ↓ (이름·설명·ID만)
                                Wall → ES canvas-search
검색어 → Spring → Wall Nginx HTTPS /internal/search/embedding → E5 worker
          ↓ Wall storage-broker → ES Nori + 원본 BM25 + k-NN
          ↓ 순위 합산 → 원본 summary _mget → 응답
```

객체, 채팅, 비밀번호, 사용자 목록은 임베딩 인덱스에 저장하지 않습니다. 응답의 사용자 수는 원본 summary를 다시 읽어 계산합니다. 기존 공개 캔버스 메타데이터 검색 권한을 변경하지 않으며 캔버스 내용 접근 권한은 별도로 검증합니다. 모델 revision이 다른 벡터는 k-NN 필터에서 제외합니다.

## 초기 구성·적용

인증서는 기존 수동 준비 절차를 사용합니다. Worker는 `agora-spring-tls`의 인증서·키를 읽기 전용으로 재사용하며 Nginx는 upstream 인증서 이름 `agora-spring`을 검증합니다. Spring→Nginx→worker와 worker→ES 모두 TLS 1.3 및 CA 검증을 사용합니다. 기존 내부 토큰으로 `/embed`를 보호하고 외부 443의 `/internal`은 차단합니다. worker의 공개 포트는 없습니다.

Orchestra `start-dev.sh` 또는 `start-deploy.sh`는 Nori ES 이미지 빌드, projection schema·계정 초기화, E5 이미지 빌드·기동을 포함합니다. 최초 배포에서는 기존 안내대로 `--initialize`를 사용합니다. 최초 E5 이미지 빌드에는 모델 다운로드가 필요합니다. `--no-build`는 Nori와 E5 이미지도 사전에 준비해야 합니다.

직접 적용할 때는 기존 DB TLS 설정과 애플리케이션을 유지하면서 다음 순서를 따릅니다(컨테이너 재생성 시 서비스 중단 가능).

```sh
# project-agora-DB에서, Nori 플러그인과 synonyms mount를 적용
# 기존 인증서·.env 준비 후 실행
docker compose up -d --build --wait elasticsearch
bash elasticsearch/init-search-index.sh
# BE에서 .env의 DB 계정·공개 CA 경로를 기존 sync 도구로 동기화
# Wall storage-broker 및 BE service TLS volume 준비 이후
docker compose --env-file .env -f docker-compose.search.yml up -d --build --wait
# 최신 Spring 이미지와 Wall Nginx 설정도 기존 실행 도구로 적용
```

검색 schema는 `canvas-search-v1`과 쓰기 alias `canvas-search`입니다. 기본 한 shard·replica 0은 단일 노드용입니다. 클러스터에서는 데이터량에 맞게 shard 설계와 replica 수를 조정하십시오. 애플리케이션 ES role에는 원본 및 projection alias/버전 index의 read/write/view-index-metadata만 추가합니다. schema 생성·analyzer reload는 관리 계정 작업입니다.

## 갱신·장애 동작

Worker는 64개씩 PIT와 search-after로 원본 메타데이터를 순회합니다. 메타데이터와 모델 revision의 fingerprint가 바뀐 문서만 다시 임베딩합니다. 성공적으로 한 번 전체 동기화해야 healthy가 됩니다. 기본 30초는 **동기화 완료 후 다음 순회까지의 대기 시간**이며 처리 시간과 ES refresh가 더해집니다. C++가 Redis에만 저장한 편집은 기존 ES snapshot 저장 시점 이후에 검색됩니다.

삭제는 각 projection ID를 원본 `_mget`으로 확인한 경우에만 수행하며 부분 실패 시 삭제를 진행하지 않습니다. 검색 응답도 원본을 재조회하여 삭제 문서를 제거합니다. 임베딩 장애·동기화 지연 중에도 원본 BM25를 함께 조회합니다. worker 상태의 `synced-at`으로 마지막 성공 시간을 확인하십시오. `/health`는 최초 동기화 완료 이후에는 최근 동기화 실패로 즉시 unhealthy가 되지는 않습니다.

문서 전체를 메모리에 적재하지 않지만 메타데이터 전체 순회 비용은 문서 수에 비례합니다. 대규모 환경에서는 `SEARCH_SYNC_SECONDS`를 늘리고 처리 지연을 측정하십시오. 이 구현은 분산 CDC나 실시간 트랜잭션 projection이 아닙니다. 여러 worker의 동시 실행은 권장하지 않습니다.

| 설정 | 기본값 |
|---|---|
| ES_SEARCH_INDEX (DB/BE 동일) | canvas-search |
| ES_SEMANTIC_SEARCH_ENABLED | true |
| ES_SEARCH_LIMIT | 100 (1–200) |
| ES_SEARCH_CANDIDATES | 500 (1–2000, k 이상) |
| ES_SEARCH_MIN_SIMILARITY | 0.80 (cosine, -1–1) |
| SEARCH_SYNC_SECONDS | 30 (1–3600) |
| EMBEDDING_THREADS | 2 (1–16) |
| SEARCH_EMBEDDING_URL | https://agora-nginx:8444/internal/search/embedding |

## 동의어와 schema 운영

`search/synonyms.txt`를 수정하면 모든 ES 노드에 같은 파일을 제공해야 합니다. 관리 계정으로 HTTPS `POST /canvas-search/_reload_search_analyzers` 후 `POST /canvas-search/_cache/clear?request=true`를 실행하십시오. 잘못된 규칙은 analyzer reload 실패를 일으킵니다. 색인 tokenizer는 mixed지만 동의어 파싱에는 discard를 사용해 같은 위치의 복합어 그래프 문제를 피합니다.

차원·analyzer 변경은 기존 원본을 지우지 말고 새로운 projection 버전 index를 만든 뒤 재색인하고 alias를 원자적으로 교체하십시오. 모델 변경은 query와 passage 모델 revision을 함께 맞춰야 합니다. 초기화 스크립트는 기존 검색 인덱스를 자동 삭제하거나 재생성하지 않습니다.

## 검증

BE에서 `python3 search/tests/run-integration.py`를 실행하면 별도 내부 Docker network에 일회성 TLS ES와 TCP broker를 만들고 Nori·동의어·한국어 오타·띄어쓰기·실제 E5 k-NN·생성/수정/삭제·비공개 필드 제외·부분 실패 시 삭제 차단·실제 Wall Nginx 경유 임베딩과 토큰/TLS 검증을 검사한 뒤 정리합니다. 사전에 두 검색 이미지를 빌드해야 합니다. 배포 중인 Agora 컨테이너는 건드리지 않습니다. Spring `CanvasSearchServiceTest`는 순위 합산, 모델 revision 필터, 임베딩·projection 장애 fallback, 삭제 문서 제외를 검증합니다.

참고: [Nori tokenizer](https://www.elastic.co/docs/reference/elasticsearch/plugins/analysis-nori-tokenizer), [synonym graph](https://www.elastic.co/guide/en/elasticsearch/reference/8.19/analysis-synonym-graph-tokenfilter.html), [k-NN](https://www.elastic.co/guide/en/elasticsearch/reference/8.19/knn-search.html), [multilingual E5 모델 카드](https://huggingface.co/intfloat/multilingual-e5-small).
