# StarRocks BMT (벤치마크)

> 이 문서는 초안이다. 검증까지 끝나면 `lessons/`로 옮겨 다듬는다. 배포 방법은 [설치](starrocks-install.md), 아키텍처 배경은 [소개](starrocks-intro.md) 참고.

shared-nothing과 shared-data 중 어느 쪽이 우리 워크로드에 맞는지 실측으로 검증했다. 진짜 로컬 스토리지(`starrocks-sn` 네임스페이스, FE+BE 3노드)와 진짜 오브젝트 스토리지(`starrocks` 네임스페이스, FE+CN 3노드, RGW 기반) 클러스터를 각각 배포해 동일한 스키마/쿼리로 비교했다. **결론부터: 측정 방법(쓰기 패턴, 데이터 규모, 동시성)에 따라 우열이 계속 뒤집혔다** — 이게 이 벤치마크 시리즈 전체의 가장 큰 교훈이다.

## CRUD 성능 비교

Primary Key 테이블(30만 행)에 INSERT/SELECT(point)/SELECT(집계)/UPDATE(upsert)/DELETE 시퀀스를 돌렸다(`SELECT NOW(6)`로 서버 사이드 시간만 측정, 클라이언트 파드 기동 오버헤드 제외).

| CRUD 작업 | shared-nothing | shared-data(RGW) | 우세 |
|---|---|---|---|
| INSERT (30만 행) | 644.5ms | 700.7ms | SN 8% |
| SELECT (point) | 16.5ms | 7.5ms | SD 2배 |
| SELECT (집계) | 42.5ms | 25.2ms | SD 68% |
| UPDATE (upsert 3만 행) | 203.4ms | 120.8ms | SD 68% |
| DELETE (3만 행) | 209.9ms | 146.6ms | SD 43% |

INSERT는 로컬이 앞서지만 조회/UPDATE/DELETE는 RGW가 빨랐다 — 아래 "반복 측정"에서 확인했듯 이 격차 상당 부분은 클러스터 워밍업 상태 차이였다.

## 대용량 로드 + 3-way JOIN(MPP)

`fact(1000만 행)` + `customer(10만)` + `product(1만)` 스타 스키마, 3-way JOIN + 필터 + GROUP BY + 정렬.

```sql
SELECT c.segment, p.category_name, COUNT(*), SUM(f.quantity * p.unit_price), AVG(f.quantity)
FROM fact f
JOIN customer c ON f.customer_id = c.customer_id
JOIN product p ON f.product_id = p.product_id
WHERE f.ts BETWEEN '2026-03-01' AND '2026-04-01'
GROUP BY c.segment, p.category_name
ORDER BY 4 DESC LIMIT 20;
```

| 테스트 | shared-nothing | shared-data(RGW) | 우세 |
|---|---|---|---|
| 1000만 행 로드 | 3.65초 | 3.92초 | SN 7% |
| 3-way JOIN + 집계 + 정렬 | 113.9ms | 102.4ms | SD 10% |

## STREAM LOAD(사전 생성 파일)로 순수 I/O 비교

데이터 생성의 CPU 비용을 배제하기 위해 Python으로 CSV(고카디널리티, 1000만 행, 2.8GB)를 미리 만들어두고 STREAM LOAD(HTTP PUT 벌크 로드)로 순수 쓰기 시간만 측정했다.

| 방식 | LoadTimeMs | WriteDataTimeMs |
|---|---|---|
| shared-nothing(2-replica) | 46,377ms | 46,321ms |
| shared-data(RGW size=2) | 54,443ms | 54,281ms |

**로컬이 15% 빠르다.** 순수 쓰기 경로에서는 shared-nothing이 우위를 보였다.

## 반복 측정으로 워밍업 노이즈 분리

### 직렬 TPS (그룹핑 쿼리 200회 연속)

CRUD의 집계 쿼리 결과(RGW가 68% 빠름)가 단발 측정 노이즈인지 확인하기 위해 동일 쿼리를 200회 연속(단일 커넥션, 30만 행 테이블) 실행했다.

| 클러스터 | 200회 총 소요 | 평균 지연 | QPS |
|---|---|---|---|
| shared-nothing | 3.79초 | 18.95ms | 52.8 |
| shared-data(RGW) | 3.34초 | 16.72ms | **59.8** |

**68% 격차가 13%로 크게 좁혀졌다.** 단발 결과 대부분이 콜드 스타트(JIT/캐시 워밍업 부족) 노이즈였다는 게 확인됐다. RGW(CN)가 여전히 소폭 우세한 건 CN의 로컬 Data Cache가 반복 조회에 유리하기 때문으로 추정 — 200회 반복이면 첫 1~2회 이후 계속 웜 상태를 유지했을 것이다.

### 동시 처리 TPS (20커넥션 × 20회)

직렬 반복은 서버의 동시 요청 처리 능력을 안 보여준다. 한 파드 안에서 mysql 클라이언트 프로세스 20개를 동시에 띄우고 각자 20회씩(총 400건) 실행해 벽시계 시간 기준 합산 QPS를 측정했다.

| 클러스터 | 동시 20커넥션 × 20회(총 400건) | 소요 | QPS |
|---|---|---|---|
| shared-nothing | 400건 | 1.27초 | **315.5** |
| shared-data(RGW) | 400건 | 2.86초 | 140.1 |

**뚜렷한 역전 — 로컬이 2.25배 빠르다.** 직렬 반복(13% RGW 우세)과 정반대 방향. CN은 쿼리마다(또는 캐시 미스마다) RGW로 네트워크 왕복을 해야 하는데, 동시 요청이 몰리면 이 경로 자체가 공유 병목이 되어 서로 대기하게 되는 것으로 보인다. 로컬 디스크(BE 3개, 노드별 분산)는 동시 요청을 병렬로 더 잘 흡수한다. **동시성이 커질수록 shared-nothing의 구조적 이점이 드러난다.**

## 동시성 병목이 정확히 어디인지 — CPU 실측 + FE 코디네이터 분산 실험

### 컨테이너 CPU 제한 확인

FE/BE/CN 파드 전부 `resources.limits.cpu`가 설정돼 있지 않다(메모리 limit/request만 있음) — k8s가 CPU를 인위적으로 조이고 있는 게 아니다.

### 노드별 CPU 실측 (mpstat)

동시 부하 테스트 중 3노드(chan08/chan09/llm001)의 CPU를 `mpstat 1`로 직접 관찰했다.

**shared-data(RGW) 20커넥션 부하 시**: chan08(FE+CN이 같이 떠 있는 노드)이 정점 88% usr까지 치솟았고, chan09(CN2, 클라이언트 파드도 여기 배치됨)는 정점 57%, **llm001(CN3, 12코어)은 거의 안 씀(idle 96%+)**.

**shared-data 60커넥션으로 올렸을 때**: QPS는 140.1 → 173.4로 늘었지만, chan08이 6초 내내 idle 1~3%까지 떨어지며 **진짜로 CPU 포화** 상태가 됐다. 반면 llm001(12코어, 2배 더 많은 코어)은 정점에도 idle 76% 이상 — 사실상 놀고 있었다.

**shared-nothing 20커넥션 부하 시**: 3노드 모두 정점 65% 이하로 고르게 분산됐고, 1.16초 만에 끝났다 — 어느 한 노드도 병목이 되지 않았다.

이 실측이 보여주는 것: 병목은 "CN 프로세스의 연산량 부족"이 아니라, **FE(쿼리 코디네이터)가 CN과 같은 노드(chan08)에 같이 떠 있어서 그 노드 하나가 막힌 것**이다. llm001에 이미 CN3가 등록돼 있는데도 부하가 그쪽으로 잘 안 갔다.

### FE 3개로 분산시켜보면 나아질까 — 실험 결과: 아니다

가설을 검증하기 위해 FE Follower 2개(fe2 on chan09, fe3 on llm001)를 추가하고, 60커넥션을 3개 FE에 고르게 나눠 붙여 재측정했다.

| 구성 | 60커넥션 QPS | chan08 | chan09 | llm001 |
|---|---|---|---|---|
| FE 1개 | 173.4 | 정점 79% usr, idle 0.8~3% | 정점 44% usr, idle 38~44% | 정점 16% usr, idle 76%+ |
| FE 3개(분산) | **158.1**(9% 감소) | 72% usr, idle 0.5~1.8% | **82% usr, idle 1~3.7%(가장 포화)** | 36% usr, idle 55~63%(여전히 여유) |

**FE를 늘려도 나아지지 않았다 — 오히려 살짝 나빠졌다.** llm001은 여전히 CPU 여유가 많았고, 오히려 chan09(fe2+cn2가 같이 떠 있게 됨)가 가장 심하게 포화됐다. 해석: FE 코디네이터의 CPU 처리량 자체가 진짜 병목이 아니었다. 진짜 제약은 **CN이 매 쿼리(또는 캐시 미스)마다 RGW로 왕복하는 네트워크 요청 자체의 직렬화 비용**이고, FE를 늘려봐야 이 경로 자체는 그대로라 도움이 안 됐다. 오히려 새 FE가 CN과 같은 노드에 같이 떠 있으면서 그 노드의 경합만 늘렸다.

**결론**: shared-data 클러스터의 동시성 확장은 "FE나 CN 개수를 늘리는" 문제가 아니라, FE/CN을 물리적으로 분리 배치하거나 RGW 자체의 동시 처리 능력(스레드/커넥션 풀)을 봐야 할 문제로 보인다 — 아래에서 두 후보를 이어서 검증했다.

### RGW 게이트웨이를 3개로 늘려보면 나아질까 — 실험 결과: 거의 안 나아짐

RGW 게이트웨이가 `instances: 1`(파드 1개, llm001에만 존재)뿐이라는 걸 확인했다 — CN 3개가 보내는 S3 요청이 전부 이 파드 하나로 몰리는 구조였다. `CephObjectStore`의 `gateway.instances`를 3으로 늘리자 Rook이 노드당 1개씩 자동으로 분산 배치했다(`rook-ceph-rgw-*` Service가 3개 엔드포인트로 로드밸런싱).

| 구성 | 20커넥션 QPS | chan08 | chan09 | llm001 |
|---|---|---|---|---|
| RGW 1개 | 140.1 | 정점 88% usr | 정점 57% usr | idle 96%+ |
| RGW 3개(노드당 1개) | 144.2(거의 동일) | 정점 77%(소폭 완화) | 정점 40%(소폭 완화) | idle 88%+ |

QPS는 거의 그대로였다. chan08(FE+CN1이 같이 있는 노드)의 CPU 정점이 88%→77%로 약간 낮아지긴 했지만 처리량엔 큰 영향이 없었다 — 이 규모(20커넥션)에서는 RGW 게이트웨이 개수가 지배적 병목이 아니었다.

### FE를 가장 여유 있는 노드로 옮겨보면 나아질까 — 실험 결과: 크게 나아진다

FE Follower 2개(효과 없었음, 위 실험)는 등록 해제 후 제거해 다시 FE 1개로 되돌리고, 그 FE를 chan08(6코어)에서 **llm001(12코어, CN3·RGW 게이트웨이도 이미 같이 있음)로 이동**시켰다(`nodeSelector`로 강제 재배치).

| 구성 | 20커넥션 QPS | chan08 | chan09 | llm001 |
|---|---|---|---|---|
| FE @ chan08(+CN1), RGW 1개 | 140.1 | 정점 88% usr | 정점 57% | idle 96%+ |
| FE @ chan08, RGW 3개 | 144.2 | 정점 77% | 정점 40% | idle 88%+ |
| **FE @ llm001(+CN3+RGW), RGW 3개** | **224.7** | 정점 56% | 정점 48% | 정점 76%(idle 최저 11%) |

**60%+ 개선.** llm001에 FE·CN3·RGW 게이트웨이가 다 같이 떠 있는데도, 코어가 2배(12 vs 6)라 여유 있게 흡수했다 — 정점에도 idle이 11%는 남았다. 반면 chan08/chan09는 이제 CN만 남아 훨씬 가벼워졌다(88%→56%, 57%→48%).

**결론**: "물리적으로 분리 배치"보다 **"가장 자원 여유 있는 노드에 코디네이터(FE)를 두는 것"**이 훨씬 효과적이었다. RGW 게이트웨이를 3배로 늘린 것(140.1→144.2, +3%)보다 FE 위치를 바꾼 것(140.1→224.7, +60%) 하나가 압도적으로 컸다 — 이번 동시성 실험 시리즈 전체에서 가장 확실한 성능 확장 레버였다.

## 정리 — 이번 벤치마크 시리즈 전체의 결론

| 측정 방법 | 결과 |
|---|---|
| CRUD 단발 측정 | 쓰기는 로컬이, 조회/UPDATE/DELETE는 RGW가 우세 |
| 대용량(GB) + 순수 쓰기(STREAM LOAD) | 로컬이 15% 빠름 |
| 소규모 조회, 200회 직렬 반복 | RGW가 13% 빠름(워밍업 배제한 정상 상태) |
| 소규모 조회, 20커넥션 동시(FE가 CN1과 같은 6코어 노드) | **로컬이 2.25배 빠름** |
| 소규모 조회, 20커넥션 동시(shared-data, FE를 가장 여유 있는 12코어 노드로 이동) | RGW가 140.1 → **224.7 QPS로 60%+ 개선** — 로컬과의 격차가 크게 좁혀짐 |

**측정 방법(쓰기 패턴, 데이터 규모, 동시성, 워밍업 상태, 노드 배치)에 따라 결론이 완전히 뒤집힌다는 것 자체가 가장 큰 교훈이다.** 단일 벤치마크 숫자로 "shared-nothing이 항상 빠르다/느리다"를 일반화할 수 없고, shared-data는 배치(FE/CN/RGW를 어느 노드에 두는지)만으로도 처리량이 크게 달라진다. 우리 워크로드를 먼저 특정하고 그에 맞는 측정 방법·배치를 골라야 한다.

## 검증하고 싶은 것 (백로그)

- [ ] point/UPDATE/DELETE도 집계처럼 반복 측정으로 워밍업 vs 구조적 차이 분리(집계만 확인함)
- [ ] `starrocks-sn` `replication_num=1`(진짜 로컬 전용, 네트워크 복제 없음)로 STREAM LOAD 재비교 — 지금은 2라 두 번째 복제본의 네트워크 비용이 섞여 있음
- [x] ~~RGW(radosgw) 자체의 동시 커넥션/스레드 설정이 동시성 병목의 원인인지 확인~~ → 게이트웨이 3배(1→3)로 늘려도 QPS 거의 그대로(140.1→144.2) — 이 규모에선 병목 아니었음(위 "RGW 게이트웨이를 3개로" 섹션)
- [x] ~~FE/CN 물리적 분리 배치 검증~~ → FE를 가장 코어가 많은 노드로 옮기니 60%+ 개선(위 "FE를 가장 여유 있는 노드로" 섹션). "분리"보다 "여유 자원이 큰 노드에 배치"가 핵심
- [ ] 60커넥션 이상 더 큰 동시성에서도 FE 배치 개선 효과가 유지되는지, 아니면 llm001도 결국 포화되는지 확인(지금은 20커넥션만 테스트함)
- [ ] Compaction이 실제로 도는 걸 관찰 — 작은 rowset을 여러 번 로드한 뒤 `SHOW TABLET`/compaction 관련 메트릭으로 확인
- [ ] Vacuum이 오래된 버전을 실제로 지우는지 — RGW 버킷 오브젝트 수 변화로 확인
- [ ] tablet 분산/실행계획을 `EXPLAIN`으로 직접 확인(지금까지는 결과 시간으로만 병렬성을 간접 추정)

## 스크립트 목록

- [`11-real-sn-vs-shared-data-benchmark.sh`](../scripts/08-starrocks/11-real-sn-vs-shared-data-benchmark.sh) — STREAM LOAD 비교
- [`12-real-sn-vs-shared-data-crud.sh`](../scripts/08-starrocks/12-real-sn-vs-shared-data-crud.sh) — CRUD 비교
- [`13-real-sn-vs-shared-data-mpp.sh`](../scripts/08-starrocks/13-real-sn-vs-shared-data-mpp.sh) — 대용량+MPP 비교
- [`14-real-sn-vs-shared-data-agg-tps.sh`](../scripts/08-starrocks/14-real-sn-vs-shared-data-agg-tps.sh) — 직렬 TPS
- [`15-real-sn-vs-shared-data-agg-concurrent-tps.sh`](../scripts/08-starrocks/15-real-sn-vs-shared-data-agg-concurrent-tps.sh) — 동시 처리 TPS
- [`16-add-fe-followers.sh`](../scripts/08-starrocks/16-add-fe-followers.sh) — FE Follower 추가(코디네이터 분산 실험, 결과적으로 원복)
- RGW 게이트웨이 3개 확장: [`04-objectstore.yaml`](../scripts/07-ceph-storage/04-objectstore.yaml)의 `gateway.instances`(1→3), [Ceph 설치](ceph-install.md) 참고
- FE를 llm001로 이동: `kubectl -n starrocks patch deployment fe --type=json -p='[{"op":"add","path":"/spec/template/spec/nodeSelector","value":{"kubernetes.io/hostname":"llm001"}}]'
