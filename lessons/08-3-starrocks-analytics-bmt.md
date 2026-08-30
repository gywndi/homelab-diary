# StarRocks 분석 엔진 벤치마크 (shared-nothing vs shared-data)

설계는 [StarRocks 분석 엔진](08-1-starrocks-analytics.md) 참고. `starrocks-sn`(FE+BE, 로컬 XFS)과 `starrocks`(FE+CN, Ceph RGW) 두 클러스터를 같은 스키마/쿼리로 비교했다. RGW(RADOS Gateway)는 Ceph가 제공하는 S3 호환 오브젝트 스토리지 API다 — 자세한 내용은 [Ceph 스토리지](07-1-ceph-storage.md) 참고. 아래에서 "RGW"는 곧 shared-data 클러스터가 데이터를 저장하는 네트워크 스토리지를 가리킨다.

## 핵심 결론

| 측정 방법 | 결과 |
|---|---|
| CRUD 단발 측정 | 쓰기는 로컬이, 조회/UPDATE는 RGW가 우세(DELETE는 오차 범위) |
| 대용량(GB) + 순수 쓰기(STREAM LOAD) | 로컬이 **1.6배** 빠름 |
| 소규모 조회, 200회 직렬 반복 | RGW가 13% 빠름(워밍업 배제한 정상 상태) |
| 소규모 조회, 20커넥션 동시(FE가 CN1과 같은 6코어 노드) | **로컬이 2.25배 빠름** |
| 소규모 조회, 20커넥션 동시(FE를 가장 여유 있는 12코어 노드로 이동) | RGW가 140.1 → **224.7 QPS로 60%+ 개선** |
| CN 1→2→3, 소규모 쿼리(20커넥션 동시) | CN 늘릴수록 QPS 소폭 **하락**(236.6→217.9) |
| CN 1→2→3, 대용량 3-way JOIN(스캔량 비례, 40회 반복 통계) | CN 1→2는 **평균 24% 단축**, 2→3은 중앙값 동일·꼬리 지연만 증가 |

**측정 방법(쓰기 패턴, 데이터 규모, 동시성, 워밍업 상태, 노드 배치, 노드 개수)에 따라 결론이 완전히 뒤집힌다.** 단일 숫자로 "로컬이 항상 빠르다" "CN을 늘리면 항상 빠르다"를 일반화할 수 없다. shared-data는 배치와 워크로드 무게에 따라 처리량이 크게 달라진다.

## CRUD / 대용량 로드 / STREAM LOAD

2026-08-30 Ceph를 Rook(k8s)에서 cephadm(베어메탈)으로 재구축한 뒤 재측정한 결과다(아래 CRUD/STREAM LOAD 두 표). MPP(3-way JOIN) 표는 이번에 다시 측정하지 않은 이전(Rook 시절) 수치로 남겨뒀다 — 참고용으로만 볼 것.

Primary Key 테이블(30만 행)에 INSERT/SELECT(point)/SELECT(집계)/UPDATE(upsert)/DELETE 시퀀스를 돌렸다.

| CRUD 작업 | shared-nothing | shared-data(RGW) | 우세 |
|---|---|---|---|
| INSERT (30만 행) | 634.1ms | 722.9ms | SN 12% |
| SELECT (point) | 8.1ms | 4.7ms | SD 42% |
| SELECT (집계) | 20.0ms | 12.0ms | SD 40% |
| UPDATE (upsert 3만 행) | 210.3ms | 144.8ms | SD 31% |
| DELETE (3만 행) | 211.2ms | 220.6ms | SN 4%(오차 범위) |

단발 측정이라 절대값은 이전 라운드와도 꽤 다르다(예: shared-nothing point SELECT가 16.5ms→8.1ms) — 인프라가 바뀌어서라기보다 그때그때의 캐시/스케줄링 상태 영향이 크다는 뜻이다. **방향(쓰기는 로컬 우세, 조회/갱신은 RGW 우세)은 일관되게 유지된다.**

`fact(1000만 행)` + `customer(10만)` + `product(1만)` 스타 스키마로 3-way JOIN도 비교했다(Rook 시절 측정, 재검증 안 함).

| 테스트 | shared-nothing | shared-data(RGW) | 우세 |
|---|---|---|---|
| 1000만 행 로드 | 3.65초 | 3.92초 | SN 7% |
| 3-way JOIN + 집계 + 정렬 | 113.9ms | 102.4ms | SD 10% |

데이터 생성의 CPU 비용을 배제하려고, 미리 만들어둔 CSV(고카디널리티, 1000만 행, 2.8GB)를 STREAM LOAD(StarRocks의 HTTP 벌크 적재 API)로 순수 쓰기 시간만 쟀다.

| 방식 | LoadTimeMs |
|---|---|
| shared-nothing | 51,571ms |
| shared-data(RGW) | 83,511ms |

**로컬이 1.6배 빠르다.** 순수 쓰기 경로는 여전히 shared-nothing이 우위지만, 격차는 이전(1.17배)보다 커졌다. 처음 이 배율이 3.1배까지 벌어져서 재조사했더니, RGW 데이터 풀의 복제본 수(size)가 의도한 2가 아니라 cephadm 기본값인 3으로 조용히 되돌아가 있었다 — [`07-1-ceph-storage.md`의 관련 알려진 이슈](07-1-ceph-storage.md#rgw-데이터-풀의-size2-결정이-재구축-과정에서-조용히-사라져-있었다) 참고. size를 2로 되돌린 뒤 재측정한 게 위 값이다. 남은 격차(1.17배 → 1.6배)는 RGW 데이터 풀의 PG(Placement Group)가 여전히 1개뿐이라 병렬 분산이 안 되는 것과, shared-nothing 자체의 런마다 편차(같은 조건에서 34.9초~51.6초까지 관측됨)가 섞여 있어서 정확한 원인 분리는 안 됐다 — 필요하면 PG 수를 늘려 추가 검증할 것.

## 워밍업 영향: 직렬 반복 vs 동시 부하

CRUD 단발 측정의 격차가 콜드 스타트 노이즈인지 확인하려고 반복 측정했다.

같은 집계 쿼리를 200회 연속(단일 커넥션, 30만 행 테이블) 돌렸다.

| 클러스터 | 평균 지연 | QPS |
|---|---|---|
| shared-nothing | 18.95ms | 52.8 |
| shared-data(RGW) | 16.72ms | **59.8** |

**68% 격차가 13%로 크게 좁혀졌다.** 단발 결과 대부분이 콜드 스타트(JIT/캐시 워밍업 부족) 노이즈였다. RGW(CN)가 여전히 소폭 우세한 건 CN의 로컬 Data Cache가 반복 조회에 유리하기 때문으로 보인다.

이번엔 mysql 클라이언트 프로세스 20개를 동시에 띄우고 각자 20회씩(총 400건) 실행했다.

| 클러스터 | 소요 | QPS |
|---|---|---|
| shared-nothing | 1.27초 | **315.5** |
| shared-data(RGW) | 2.86초 | 140.1 |

**뚜렷한 역전 — 로컬이 2.25배 빠르다.** 직렬 반복과 정반대 방향이다. CN은 쿼리마다(또는 캐시 미스마다) RGW로 네트워크 왕복을 해야 한다. 동시 요청이 몰리면 이 경로 자체가 공유 병목이 된다. 로컬 디스크(BE 3개, 노드별 분산)는 동시 요청을 병렬로 더 잘 흡수한다.

## 동시성 병목의 원인과 해법: FE 배치

3노드(chan08/chan09/llm001)의 CPU를 `mpstat`으로 직접 관찰했다. shared-data 20커넥션 부하에서 chan08(FE+CN1이 같이 있는 노드)이 88% usr까지 치솟았다. 반면 llm001(CN3, 12코어)은 거의 안 썼다(idle 96%+). shared-nothing은 3노드 모두 65% 이하로 고르게 분산됐다.

병목은 "CN의 연산량 부족"이 아니었다. **FE(쿼리 코디네이터)가 CN과 같은 노드에 같이 떠 있어서 그 노드 하나가 막힌 것**이었다.

세 가지 해법을 시도했다.

| 구성 | 20커넥션 QPS | 비고 |
|---|---|---|
| FE @ chan08(+CN1), RGW 1개 | 140.1 | 기준 |
| FE Follower 2개로 분산(60커넥션 기준) | 158.1 | 60커넥션 QPS는 173.4→158.1로 **오히려 9% 감소** |
| RGW 게이트웨이 1개 → 3개(노드당 1개) | 144.2 | 거의 그대로(+3%) |
| **FE를 가장 여유 있는 노드(llm001, 12코어)로 이동** | **224.7** | **+60%** |

FE를 늘려 분산해도 나아지지 않았다. 진짜 제약은 CN이 매 쿼리마다 RGW로 왕복하는 네트워크 요청 자체의 직렬화 비용이었다. FE 코디네이터의 CPU 처리량은 진짜 병목이 아니었다. RGW 게이트웨이를 3배로 늘려도 거의 그대로였다 — 이 규모에서는 게이트웨이 개수가 지배적 병목이 아니었다.

**"가장 자원 여유 있는 노드에 코디네이터(FE)를 두는 것"이 압도적으로 효과적이었다.** RGW를 3배로 늘린 것(+3%)보다 FE 위치를 바꾼 것(+60%) 하나가 훨씬 컸다.

## CN 개수 확장 효과: 쿼리 무게에 따라 다르다

FE 배치까지 끝낸 상태에서 CN을 1개→2개→3개로 늘려가며 두 워크로드로 비교했다.

소규모/저비용 쿼리(30만 행, GROUP BY, 20커넥션 동시):

| CN 개수 | QPS |
|---|---|
| CN=1 | **236.6** |
| CN=2 | 225.9 |
| CN=3 | 217.9 |

**CN을 늘릴수록 오히려 소폭 하락한다(약 7~8%).** 쿼리가 가벼우면 CN이 1개일 때 전부 한 프로세스 안에서 끝난다. CN이 늘면 FE가 쿼리 조각을 분산하고 결과를 다시 합치는 오버헤드가 병렬화 이득보다 커진다.

대용량/고비용 쿼리(3-way JOIN, 스캔량을 테이블 크기의 30%로 고정, 40회 반복 통계):

| CN 개수 | 평균 지연 | 중앙값 | 표준편차 |
|---|---|---|---|
| CN=1 | 108.8ms | 111.0ms | 36.3ms |
| CN=2 | **82.4ms** | 72.4ms | 23.8ms |
| CN=3 | 99.3ms | 72.9ms | 38.2ms |

**CN=1→2는 확실한 이득이다(평균 24% 단축, 40회 표본으로 통계적으로 유의).** CN=2→3은 애매하다 — 중앙값은 거의 같은데(72.4ms vs 72.9ms) CN=3의 표준편차가 훨씬 크다(23.8ms→38.2ms). "전형적인" 실행 속도는 CN=2와 CN=3이 사실상 같다. 다만 CN=3은 가끔 훨씬 느린 실행(꼬리 지연)이 섞여 평균과 p95를 끌어올린다. "느려짐"이 아니라 "가끔 꼬리 지연이 섞임"이 정확한 설명이다.

이 쿼리 구조(dimension 테이블이 작아 broadcast join으로 처리됨)는 병렬도 2에서 수렴한다. CN=1→2는 fact 스캔이 정확히 절반으로 쪼개지는 뚜렷한 이득이 있다. CN=3에서는 dimension broadcast 비용과 결과 병합이 고정 비용으로 작용해 추가 분할의 이득을 상쇄한다.

**"CN 개수 = 성능"이라는 단순 공식은 성립하지 않는다.** 쿼리가 가벼우면 CN을 늘릴수록 오히려 손해다. 무거운 쿼리도 CN=3부터는 이득이 불확실하다. 워크로드별로 적정 CN 개수를 충분한 반복 횟수로 실측해야 한다.

### 알려진 함정: 스캔량을 비례시키지 않으면 착시가 생긴다

처음엔 테이블을 1000만→5000만 행으로 5배 늘려 같은 날짜 필터로 재측정했다. "CN 1→2배 개선, 2→3 수렴"으로 보였다. 하지만 필터가 절대 달력 날짜(`BETWEEN '2026-03-01' AND '2026-04-01'`)였다. 그래서 테이블을 5배로 늘려도 **필터를 통과하는 절대 행수가 항상 268만 행으로 고정**돼 있었다. `EXPLAIN ANALYZE`의 `OutputRows`로 확인했다. 테이블 크기와 무관하게 스캔량이 똑같으면 "더 무거운 쿼리"가 아니다. 스캔량을 테이블 크기에 비례하게(`WHERE id <= N*0.3`처럼) 고정한 뒤에야 위 표의 신뢰할 수 있는 CN 확장 결과를 얻었다.

## 스크립트 목록 (이름 순)

### STREAM LOAD 비교
- 설명: shared-nothing과 shared-data 클러스터에 같은 CSV를 STREAM LOAD로 적재해 순수 쓰기 시간을 비교한다.
- 스크립트: [`11-real-sn-vs-shared-data-stream-load.sh`](../scripts/08-starrocks/11-real-sn-vs-shared-data-stream-load.sh)

### CRUD 비교
- 설명: INSERT/SELECT(point)/SELECT(집계)/UPDATE/DELETE 시퀀스를 양쪽 클러스터에서 비교한다.
- 스크립트: [`12-real-sn-vs-shared-data-crud.sh`](../scripts/08-starrocks/12-real-sn-vs-shared-data-crud.sh)

### 대용량 + MPP 비교
- 설명: fact/customer/product 스타 스키마 로드와 3-way JOIN을 양쪽 클러스터에서 비교한다.
- 스크립트: [`13-real-sn-vs-shared-data-mpp.sh`](../scripts/08-starrocks/13-real-sn-vs-shared-data-mpp.sh)

### 직렬/동시 TPS
- 설명: 같은 집계 쿼리를 같은 테이블에 대해 직렬(단일 커넥션 200회 연속 — 워밍업 이후 정상 상태 지연)과 동시(mysql 클라이언트 20개 동시 실행 — 동시성 부하 QPS) 두 방식으로 순서대로 측정한다.
- 스크립트: [`14-real-sn-vs-shared-data-agg-tps.sh`](../scripts/08-starrocks/14-real-sn-vs-shared-data-agg-tps.sh)

### FE 코디네이터 분산 실험
- 설명: FE Follower를 늘려 코디네이터 분산 효과를 확인했다(결과적으로 효과 없어 원복 — 이 절 본문 참고). 이후 투표에 영향 없는 Observer로 방향을 바꿨다 — [concepts/03-starrocks.md](../concepts/03-starrocks.md#fe-확장-follower-vs-observer)와 [17-add-fe-observer.sh](../scripts/08-starrocks/17-add-fe-observer.sh) 참고.

### 수동 조작(스크립트 없음)
FE 배치·CN 개수·RGW 게이트웨이 개수 실험은 별도 스크립트 없이 아래 명령을 그때그때 직접 실행했다.

```bash
# RGW 게이트웨이 개수 조정(cephadm 배치 선언 재적용)
sudo cephadm shell -- ceph orch apply rgw starrocks-store --placement="chan08,chan09,llm001"

# CN 등록/해제(개수 확장 실험)
ALTER SYSTEM ADD COMPUTE NODE "...";
ALTER SYSTEM DROP COMPUTE NODE "...";

# FE를 가장 여유 있는 노드(llm001)로 이동
kubectl -n starrocks patch deployment fe --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/nodeSelector","value":{"kubernetes.io/hostname":"llm001"}}]'
```

---

[← 이전: StarRocks 베어메탈 구축](08-2-starrocks-baremetal.md) · [다음: StarRocks 아카이브 적합성 →](08-4-starrocks-archive-fitness.md)
