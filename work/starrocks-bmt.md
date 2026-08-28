# StarRocks BMT (벤치마크)

> 이 문서는 초안이다. 검증까지 끝나면 `lessons/`로 옮겨 다듬는다. 배포 방법은 [설치](starrocks-install.md), 아키텍처 배경은 [소개](starrocks-intro.md) 참고.

shared-nothing과 shared-data 중 어느 쪽이 우리 워크로드에 맞는지 실측으로 검증하기 위해 여러 라운드에 걸쳐 벤치마크를 반복했다. **결론부터: 측정 방법(쓰기 패턴, 데이터 규모, 동시성)에 따라 우열이 계속 뒤집혔다** — 이게 이 벤치마크 시리즈 전체의 가장 큰 교훈이다.

## ⚠️ 중요한 정정: 초반 라운드는 전부 cloud-native끼리의 비교였다

시간 단위 파티션(`PARTITION BY RANGE(...) EVERY(INTERVAL 1 HOUR)`)을 검증하다가 발견했다. `replication_num`을 지정해 만든 "BE(로컬)" 테이블의 `SHOW CREATE TABLE`을 열어보니 `"storage_volume" = "builtin_storage_volume"`, `"datacache.enable" = "true"`가 붙어 있었다 — **cloud-native(RGW 기반) 테이블이라는 표시**다. 확인해보니:

- BE 로컬 스토리지 경로(`/mnt/starrocks-be/data`)가 **0바이트**였다. `datacache`(로컬 캐시, 4.2GB)만 있었다.
- 세션 최초 검증 테이블(`t1`)도 동일하게 cloud-native였다.

원인: `run_mode = shared_data`로 띄운 FE는 **테이블 속성과 무관하게 CREATE TABLE이 항상 cloud-native로 만들어진다.** 공식 문서로 재확인:

> "Mixed deployment of shared-nothing and shared-data mode is not supported, and the transformation from a shared-nothing cluster to a shared-data cluster or vice versa is not supported." — [S3용 shared-data 배포](https://docs.starrocks.io/docs/deployment/shared_data/s3/)
> "local disk serves as Data Cache, not primary storage" — [shared-data FAQ](https://docs.starrocks.io/docs/faq/shared_data_faq/)

즉 아래 "1라운드: 초기 비교"에 기록한 모든 결과는 실제로는 **"cloud-native 테이블을 BE 프로세스가 실행 vs CN 프로세스가 실행"**의 차이였다 — 스토리지 위치(로컬 XFS vs RGW) 차이가 전혀 아니었다. `run_mode`는 클러스터 생성 시 고정되고 나중에 못 바꾸므로, 완전히 별도의 FE(`starrocks-sn` 네임스페이스, `run_mode` 미지정)를 새로 배포해 진짜 로컬 스토리지 클러스터를 만들고 "2라운드: 정정된 재비교"부터 다시 측정했다.

진짜 로컬 클러스터임을 검증한 방법: `SHOW CREATE TABLE`에 `storage_volume`이 아예 없고 `"replicated_storage" = "true"`만 있음(classic OLAP 표시), 노드의 `/mnt/starrocks-be/sn-data/data`에 실제로 바이트가 쌓이는 것 확인, `SHOW TABLET`이 cloud-native와 다른 스키마(태블릿마다 `ReplicaId`가 있고 replication_num만큼 여러 행)로 나옴.

## 1라운드: 초기 비교 (⚠️ 전부 cloud-native끼리의 비교, 위 정정 참고)

### CRUD 성능 비교

동일한 Primary Key 테이블/데이터로 CRUD 시퀀스를 돌려 비교했다(`SELECT NOW(6)`로 서버 사이드 시간만 측정).

| CRUD 작업 | "BE"(2-replica) | "CN"(RGW size=2) |
|---|---|---|
| INSERT (30만 행) | 741.4ms | 716.6ms |
| SELECT (point) | 10.0ms | 5.9ms |
| SELECT (집계) | 26.6ms | 19.6ms |
| UPDATE (upsert 3만 행) | 122.1ms | 136.2ms |
| DELETE (3만 행) | 126.6ms | 137.3ms |

거의 동등 — 이 규모(수 MB)에서는 스토리지 계층보다 FE의 쿼리 플래닝/실행 오버헤드가 지배적인 것으로 보였다.

### 대용량 로드 + 3-way JOIN(MPP)

`fact(1000만 행)` + `customer(10만)` + `product(1만)` 스타 스키마, 3-way JOIN + 필터 + GROUP BY + 정렬.

| 테스트 | "BE" | "CN" |
|---|---|---|
| 1000만 행 로드 | 4.00초 | 3.92초 |
| 3-way JOIN + 집계 + 정렬 | 183ms | 94ms |

여전히 거의 동등 — `id % N` 패턴의 저카디널리티 합성 데이터라 컬럼 압축(RLE/딕셔너리)이 매우 효율적으로 먹혀서, 실제 바이트량이 1GbE 병목(86MB/s, [Ceph BMT](ceph-bmt.md) 참고)에 도달할 만큼 크지 않았던 것으로 추정.

### 고카디널리티 데이터로 재검증

행마다 MD5 해시 8개(~256바이트)를 이어붙인 사실상 무작위 `payload` 컬럼 추가.

| 규모 | "BE" | "CN" | 차이 |
|---|---|---|---|
| 1000만 행 로드 | 51.2초 | 62.4초 | **CN이 22% 느림** — 1GbE 병목 최초 관측 |
| 1000만 행 집계 쿼리 | 177ms | 192ms | CN이 8% 느림 |
| 3000만 행 로드 | 160.3초 | 163.5초 | CN이 2% 느림(거의 사라짐) |

3000만 행에서 차이가 다시 사라진 이유: `INSERT...SELECT`로 `MD5(CONCAT(id,RAND()))`를 행마다 8번씩 서버 사이드에서 계산하는데, 이 규모(2.4억 회 MD5 연산)에서는 순수 스토리지 I/O가 아니라 **데이터 생성 자체의 CPU 비용이 병목**이 되어 차이를 가렸다.

### STREAM LOAD(사전 생성 파일)로 순수 I/O 비교

CPU 비용을 완전히 분리하기 위해 Python으로 CSV(1000만 행, 2.8GB)를 미리 만들어두고 STREAM LOAD(HTTP PUT 벌크 로드)로 순수 쓰기 시간만 측정.

| 방식 | LoadTimeMs | WriteDataTimeMs |
|---|---|---|
| "BE"(2-replica) | 67,289ms | 67,087ms |
| "CN"(RGW size=2) | 55,571ms | 55,406ms |

**정반대 — CN이 17% 더 빠르다.** 해석(정정 전 기준): "BE"도 `replication_num=2`라 두 번째 복제본을 다른 노드로 네트워크 전송해야 하니 "로컬이라 네트워크 비용 없음"이 성립하지 않는다는 가설이었으나, ⚠️ 애초에 "BE" 자체가 cloud-native였으므로 이 해석은 무효 — 실제로는 cloud-native 테이블을 BE 프로세스가 실행 vs CN 프로세스가 실행한 차이였다.

## 2라운드: 정정된 재비교 (진짜 shared-nothing vs 진짜 shared-data)

동일한 스키마/쿼리로 `starrocks-sn`(진짜 로컬) vs `starrocks`(진짜 RGW, cloud-native — 이쪽은 애초에 문제없었다)를 다시 측정했다.

| 벤치마크 | 진짜 shared-nothing | 진짜 shared-data(RGW) | 우세 |
|---|---|---|---|
| CRUD INSERT(30만 행) | 644.5ms | 700.7ms | SN 8% |
| CRUD SELECT(point) | 16.5ms | 7.5ms | SD 2배 |
| CRUD SELECT(집계) | 42.5ms | 25.2ms | SD 68% |
| CRUD UPDATE | 203.4ms | 120.8ms | SD 68% |
| CRUD DELETE | 209.9ms | 146.6ms | SD 43% |
| 대용량 로드(1000만 행) | 3.65초 | 3.92초 | SN 7% |
| 3-way JOIN + 집계 + 정렬 | 113.9ms | 102.4ms | SD 10% |
| STREAM LOAD(1000만 행, 사전 생성 파일) | 46,377ms | 54,443ms | **SN 15%** |

뚜렷한 일방적 승자가 없다. 대량 순수 쓰기(STREAM LOAD, INSERT)는 로컬이 앞서는데, 소규모 point/집계/UPDATE/DELETE는 오히려 RGW 쪽이 빨랐다 — 막 기동한 SN 클러스터의 워밍업 부족이 의심되어 아래 3라운드에서 반복 측정으로 분리했다.

## 3라운드: 반복 측정으로 워밍업 노이즈 분리

### 직렬 TPS (그룹핑 쿼리 200회 연속)

CRUD의 집계 쿼리(RGW가 68% 빠름)가 단발 측정 노이즈인지 확인하기 위해 동일 쿼리를 200회 연속(단일 커넥션, 30만 행 테이블) 실행.

| 클러스터 | 200회 총 소요 | 평균 지연 | QPS |
|---|---|---|---|
| 진짜 로컬(SN) | 3.79초 | 18.95ms | 52.8 |
| 진짜 RGW(SD) | 3.34초 | 16.72ms | **59.8** |

**68% 격차가 13%로 크게 좁혀졌다.** CRUD 단발 결과 대부분이 SN 클러스터의 콜드 스타트(막 기동한 BE, JIT/캐시 워밍업 부족) 노이즈였다는 게 확인됨. RGW(CN)가 여전히 소폭 우세한 건 CN의 로컬 Data Cache가 반복 조회에 유리하기 때문으로 추정 — 200회 반복이면 첫 1~2회 이후 계속 웜 상태를 유지했을 것이다.

### 동시 처리 TPS (20커넥션 × 20회)

직렬 반복은 서버의 동시 요청 처리 능력을 안 보여준다. 한 파드 안에서 mysql 클라이언트 프로세스 20개를 동시에 띄우고 각자 20회씩(총 400건) 실행해 벽시계 시간 기준 합산 QPS를 측정.

| 클러스터 | 동시 20커넥션 × 20회(총 400건) | 소요 | QPS |
|---|---|---|---|
| 진짜 로컬(SN) | 400건 | 1.27초 | **315.5** |
| 진짜 RGW(SD) | 400건 | 2.86초 | 140.1 |

**뚜렷한 역전 — 로컬이 2.25배 빠르다.** 직렬 반복(13% RGW 우세)과 정반대 방향. CN은 쿼리마다(또는 캐시 미스마다) RGW로 네트워크 왕복을 해야 하는데, 동시 요청이 몰리면 이 경로 자체가 공유 병목이 되어 서로 대기하게 되는 것으로 보인다. 로컬 디스크(BE 3개, 노드별 분산)는 동시 요청을 병렬로 더 잘 흡수한다. **동시성이 커질수록 shared-nothing의 구조적 이점이 드러난다.**

## 4라운드: 동시성 병목이 정확히 어디인지 — CPU 실측 + FE 코디네이터 분산 실험

### 컨테이너 CPU 제한 확인

FE/BE/CN 파드 전부 `resources.limits.cpu`가 설정돼 있지 않다(메모리 limit/request만 있음) — k8s가 CPU를 인위적으로 조이고 있는 게 아니다.

### 노드별 CPU 실측 (mpstat)

동시 부하 테스트 중 3노드(chan08/chan09/llm001)의 CPU를 `mpstat 1`로 직접 관찰했다.

**shared-data(RGW) 20커넥션 부하 시**: chan08(FE+CN이 같이 떠 있는 노드)이 정점 88% usr까지 치솟았고, chan09(CN2, 클라이언트 파드도 여기 배치됨)는 정점 57%, **llm001(CN3, 12코어)은 거의 안 씀(idle 96%+)**.

**shared-data 60커넥션으로 올렸을 때**: QPS는 140.1 → 173.4로 늘었지만, chan08이 6초 내내 idle 1~3%까지 떨어지며 **진짜로 CPU 포화** 상태가 됐다. 반면 llm001(12코어, 2배 더 많은 코어)은 정점에도 idle 76% 이상 — 사실상 놀고 있었다.

**shared-nothing(SN) 20커넥션 부하 시**: 3노드 모두 정점 65% 이하로 고르게 분산됐고, 1.16초 만에 끝났다 — 어느 한 노드도 병목이 되지 않았다.

이 실측이 보여주는 것: 병목은 "CN 프로세스의 연산량 부족"이 아니라, **FE(쿼리 코디네이터)가 CN과 같은 노드(chan08)에 같이 떠 있어서 그 노드 하나가 막힌 것**이다. llm001에 이미 CN3가 등록돼 있는데도 부하가 그쪽으로 잘 안 갔다.

### FE 3개로 분산시켜보면 나아질까 — 실험 결과: 아니다

가설을 검증하기 위해 FE Follower 2개(fe2 on chan09, fe3 on llm001)를 추가하고, 60커넥션을 3개 FE에 고르게 나눠 붙여 재측정했다.

| 구성 | 60커넥션 QPS | chan08 | chan09 | llm001 |
|---|---|---|---|---|
| FE 1개 | 173.4 | 정점 79% usr, idle 0.8~3% | 정점 44% usr, idle 38~44% | 정점 16% usr, idle 76%+ |
| FE 3개(분산) | **158.1**(9% 감소) | 72% usr, idle 0.5~1.8% | **82% usr, idle 1~3.7%(가장 포화)** | 36% usr, idle 55~63%(여전히 여유) |

**FE를 늘려도 나아지지 않았다 — 오히려 살짝 나빠졌다.** llm001은 여전히 CPU 여유가 많았고, 오히려 chan09(fe2+cn2가 같이 떠 있게 됨)가 가장 심하게 포화됐다. 해석: FE 코디네이터의 CPU 처리량 자체가 진짜 병목이 아니었다. 진짜 제약은 **CN이 매 쿼리(또는 캐시 미스)마다 RGW로 왕복하는 네트워크 요청 자체의 직렬화 비용**이고, FE를 늘려봐야 이 경로 자체는 그대로라 도움이 안 됐다. 오히려 새 FE가 CN과 같은 노드에 같이 떠 있으면서 그 노드의 경합만 늘렸다.

**결론**: shared-data 클러스터의 동시성 확장은 "FE나 CN 개수를 늘리는" 문제가 아니라, FE/CN을 물리적으로 분리 배치하거나 RGW 자체의 동시 처리 능력(스레드/커넥션 풀)을 봐야 할 문제로 보인다 — 이 부분은 아직 검증 안 됨(아래 백로그).

## 정리 — 이번 벤치마크 시리즈 전체의 결론

| 측정 방법 | 결과 |
|---|---|
| 소량(수 MB), 저카디널리티 | 차이 없음, FE 오버헤드가 지배적 |
| 대용량(GB) + CPU 비용 있는 생성(INSERT+MD5) | RGW가 22% 느림(1GbE 병목 관측) |
| 대용량(GB) + 순수 쓰기(STREAM LOAD, 진짜 로컬 vs 진짜 RGW) | 로컬이 15% 빠름 |
| 소규모 조회, 단발 측정 | RGW가 68% 빠름(대부분 워밍업 노이즈) |
| 소규모 조회, 200회 직렬 반복 | RGW가 13% 빠름(정상 상태) |
| 소규모 조회, 20커넥션 동시 | **로컬이 2.25배 빠름** |

**측정 방법(쓰기 패턴, 데이터 규모, 동시성, 워밍업 상태)에 따라 결론이 완전히 뒤집힌다는 것 자체가 가장 큰 교훈이다.** 단일 벤치마크 숫자로 "shared-nothing이 항상 빠르다/느리다"를 일반화할 수 없다. 우리 워크로드(동시 조회가 잦은 서비스라면 shared-nothing 쪽이, 대용량 배치 적재 위주라면 방식에 따라 다름)를 먼저 특정하고 그에 맞는 측정 방법을 골라야 한다.

## 검증하고 싶은 것 (백로그)

- [ ] point/UPDATE/DELETE도 집계처럼 반복 측정으로 워밍업 vs 구조적 차이 분리(집계만 확인함)
- [ ] `starrocks-sn` `replication_num=1`(진짜 로컬 전용, 네트워크 복제 없음)로 STREAM LOAD 재비교 — 지금은 2라 두 번째 복제본의 네트워크 비용이 섞여 있음
- [ ] RGW(radosgw) 자체의 동시 커넥션/스레드 설정이 동시성 병목의 원인인지 확인 — 4라운드에서 "FE를 늘려도 안 됨"까지는 확인했지만 RGW 쪽 튜닝은 아직 안 해봄
- [ ] Compaction이 실제로 도는 걸 관찰 — 작은 rowset을 여러 번 로드한 뒤 `SHOW TABLET`/compaction 관련 메트릭으로 확인
- [ ] Vacuum이 오래된 버전을 실제로 지우는지 — RGW 버킷 오브젝트 수 변화로 확인
- [ ] tablet 분산/실행계획을 `EXPLAIN`으로 직접 확인(지금까지는 결과 시간으로만 병렬성을 간접 추정)

## 스크립트 목록

- [`05-crud-benchmark.sh`](../scripts/08-starrocks/05-crud-benchmark.sh) — 1라운드 CRUD (⚠️ cloud-native끼리 비교)
- [`06-mpp-benchmark.sh`](../scripts/08-starrocks/06-mpp-benchmark.sh) — 1라운드 대용량+MPP (⚠️ cloud-native끼리 비교)
- [`07-high-cardinality-benchmark.sh`](../scripts/08-starrocks/07-high-cardinality-benchmark.sh) — 1라운드 고카디널리티 (⚠️ cloud-native끼리 비교)
- [`08-stream-load-benchmark.sh`](../scripts/08-starrocks/08-stream-load-benchmark.sh) — 1라운드 STREAM LOAD (⚠️ cloud-native끼리 비교)
- [`11-real-sn-vs-shared-data-benchmark.sh`](../scripts/08-starrocks/11-real-sn-vs-shared-data-benchmark.sh) — 2라운드 STREAM LOAD 재비교
- [`12-real-sn-vs-shared-data-crud.sh`](../scripts/08-starrocks/12-real-sn-vs-shared-data-crud.sh) — 2라운드 CRUD 재비교
- [`13-real-sn-vs-shared-data-mpp.sh`](../scripts/08-starrocks/13-real-sn-vs-shared-data-mpp.sh) — 2라운드 대용량+MPP 재비교
- [`14-real-sn-vs-shared-data-agg-tps.sh`](../scripts/08-starrocks/14-real-sn-vs-shared-data-agg-tps.sh) — 3라운드 직렬 TPS
- [`15-real-sn-vs-shared-data-agg-concurrent-tps.sh`](../scripts/08-starrocks/15-real-sn-vs-shared-data-agg-concurrent-tps.sh) — 3라운드 동시 처리 TPS
- [`16-add-fe-followers.sh`](../scripts/08-starrocks/16-add-fe-followers.sh) — 4라운드 FE Follower 추가(코디네이터 분산 실험)
