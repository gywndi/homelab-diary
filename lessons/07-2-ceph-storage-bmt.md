# Ceph 스토리지 벤치마크

설계는 [Ceph 스토리지](07-1-ceph-storage.md) 참고. RBD 자체가 실사용 가능한 성능인지 측정했다.

## 핵심 결론

| 항목 | 결과 |
|---|---|
| Ceph 쓰기(`rados bench`, 4MB obj, 16 threads, rbd-pool) | 85.5 MB/s, 평균 지연 740ms |
| Ceph 순차 읽기 | 149.7 MB/s, 평균 지연 420ms |
| Ceph 랜덤 읽기 | 147.2 MB/s, 평균 지연 430ms |
| 병목 원인 | 디스크가 아니라 **1GbE 네트워크**(3노드 전부 NIC 상한 1000Mb/s) |

`rados bench`는 Ceph가 자체 제공하는 성능 측정 도구다. 개선하려면 디스크 교체는 의미 없다. NIC을 10GbE로 올리는 것만이 실질적 해법이다. 지금 규모에선 문제없지만, 트래픽이 커지면 이 지점이 먼저 막힌다.

2026-08-30 Rook(k8s)에서 cephadm(베어메탈)으로 재구축한 뒤 재측정했다. 쓰기는 이전 측정(86 MB/s, 738ms)과 사실상 동일 — RBD(블록) 레이어 자체의 성능은 배포 방식과 무관하다는 걸 재확인했다. 읽기는 약 7~9% 낮게 나왔는데, OSD가 이제 LVM 논리 볼륨으로 한 겹 더 감싸져 있는 것([`07-1-ceph-storage.md`](07-1-ceph-storage.md) 참고) 정도가 후보지만 오차 범위일 가능성도 있다 — 재측정 없이 단정하지 않는다.

이 문서는 Ceph 자체(RBD) 레이어만 다룬다. RBD 위에서 도는 MySQL의 성능 튜닝은 [MySQL을 Ceph RBD로 재배포](03-2-mysql-ceph-migration.md) 참고. RGW(오브젝트) 위에서 도는 다른 워크로드의 성능은 해당 워크로드의 벤치마크 문서에서 따로 다룬다.

## 병목 분석: 디스크가 아니라 1GbE 네트워크였다

하나씩 배제해서 좁혔다.
- 디스크 하드웨어: 3노드 전부 SSD/NVMe(회전형 없음) — 후보 제외
- OSD 자체 쓰기 지연: `ceph osd perf` 기준 commit/apply 지연 1~2ms — 후보 제외
- 네트워크 링크 상태: `iperf3`로 chan08↔chan09 실측 941Mbps, 재전송 0 — 링크 자체는 건강
- **네트워크 대역폭 상한: 3노드 전부 물리 NIC이 1GbE** — 이게 실제 병목

size=3 replication 쓰기는 클라이언트→primary OSD로 들어온다. 그다음 primary가 나머지 2개 replica로 다시 내보내야 완료 처리된다. primary 노드의 NIC 하나가 "받는 트래픽 + 내보내는 트래픽 ×2"를 전부 같은 1Gbps 파이프로 처리해야 한다. 그래서 원본 링크 속도(iperf3 실측 117MB/s)보다 실제 쓰기 처리량(86MB/s)이 낮고 지연도 커진다.

## erasure coding vs replication — 실측 (2026-08-31, 2026-09-03 추가)

개념 설명은 [concepts/02-ceph.md의 erasure coding 항목](../concepts/02-ceph.md#erasure-coding--replication보다-용량-효율적인-대안) 참고. 3노드에 임시 테스트 풀을 만들어 실측했다(측정 후 전부 삭제).

**순차 쓰기/읽기** (`rados bench`, 4MB 오브젝트, 30초)

| 방식 | 쓰기 | 읽기 | 장애 허용 |
|---|---|---|---|
| replicated size=2 | 101.8 MB/s | **165.4 MB/s** | 1대 |
| replicated size=3(`rbd-pool`, 위 핵심 결론) | 85.5 MB/s | 149.7 MB/s | 2대 |
| EC k=2,m=1 | **108.4 MB/s** | 125.2 MB/s | 1대 |

replica 3과 비교하면 EC 쓰기가 27% 빠른 것처럼 보이지만, replica 3은 애초에 장애 허용이 한 단계 높아(2대) 네트워크에 더 많이 실어 날라야 하는 조건이 다른 비교다. **같은 1대 장애 허용끼리(replica 2 vs EC) 맞추면 EC 쓰기 우위는 6.5%로 줄고, 읽기는 오히려 EC가 24% 더 느리다.** 이 클러스터(1GbE 병목)에서 EC가 쓰기 때 네트워크로 보내는 데이터가 적어(150% vs 200%) 근소하게 유리하지만, 읽기는 조각을 모아 재구성해야 해서 항상 손해다.

**RBD 랜덤 소규모 쓰기** (`rbd bench --io-type write --io-pattern rand --io-size 4K --io-total 200M`)

| 방식 | IOPS | 처리량 | 장애 허용 |
|---|---|---|---|
| replicated size=2 | 21,566 | 84 MiB/s | 1대 |
| replicated size=3 | 8,971 | 35 MiB/s | 2대 |
| **EC k=2,m=1** | **1,171** | **4.6 MiB/s** | 1대 |

같은 1대 장애 허용 수준끼리 비교해도(size=2 vs EC k=2,m=1) EC가 **18배 느리다.** read-modify-write 페널티(조각 일부를 고칠 때 관련 조각을 다시 읽고 패리티를 재계산하는 비용)가 이론적 예상보다 훨씬 크게 실측됐다 — 저장 공간은 25%(size=2 대비) 아끼지만 랜덤 쓰기 성능은 20분의 1 수준으로 떨어진다.

**소규모 오브젝트 순차 쓰기 — 로그 적재 패턴** (`rados bench`, 64KB 오브젝트, 20초 — access log를 주기적으로 배치 업로드하는 실제 파이프라인 패턴 시뮬레이션)

| 방식 | 대역폭 | IOPS | 지연 |
|---|---|---|---|
| replicated size=3 | **48.9 MB/s** | 782 | 최대 74ms |
| EC k=2,m=1 | 37.5 MB/s | 599 | 최대 2.1초, 순간 대역폭 0 발생 |

4MB 오브젝트에서는 EC가 빨랐지만 64KB로 작아지면 **역전된다**(replica3가 30% 빠름) — 오브젝트가 작을수록 EC의 조각 분할·패리티 계산 오버헤드가 전송량 절감분보다 커진다. 지연도 EC 쪽이 훨씬 불안정하다.

**RADOS append(한 오브젝트에 계속 이어쓰기)** (`rados append`, 45바이트 줄 500회)

- EC 풀은 기본적으로 append가 거부된다(`Operation not supported`) — `allow_ec_overwrites true`를 켜야 동작한다.
- 켜도 replicated보다 25% 느리다(61.6ms vs 49.1ms/append) — RBD 랜덤쓰기(18배)보다는 훨씬 덜하지만 손해는 손해다.

**결론**: 순차 쓰기·읽기는 오브젝트 크기에 따라 결과가 갈린다 — MB급 큰 오브젝트(4MB)에서는 EC가 유리하지만(같은 장애 허용 기준 쓰기 +6.5%/읽기 -24%, 저장 공간 25% 절약이 실이득), 로그 배치처럼 작은 오브젝트(64KB)에서는 오히려 EC가 손해다. 진짜 append는 EC에서 기본 차단되고 켜도 25% 느리다. RBD처럼 랜덤 소규모 쓰기가 잦은 워크로드에는 이 클러스터 규모(3노드)에서 EC가 전혀 맞지 않는다(18배 느림). MySQL/KVM(RBD)은 지금처럼 replicated를 유지하는 게 맞고, RGW(오브젝트) 쪽은 배치를 MB급으로 크게 모아 쓰는 워크로드에 한해 EC 전환을 검토해볼 만하다.

## CephFS 로그 적재 성능 (조사 중)

append 처리량, fsync 내구성/처리량 트레이드오프, IO 스케줄러 영향을 실측 중이다 — 아직 라운드가 더 필요해 결론을 여기 확정해 넣지 않았다. 현재까지 기록은 [work/cephfs-log-ingestion.md](../work/cephfs-log-ingestion.md) 참고.

## 남아있는 리스크

- Ceph usable 용량(재분할 후 약 700GiB대)을 RBD와 RGW가 통째로 나눠 쓴다. MySQL(17G)+KVM 데이터와 RGW에 올라간 다른 워크로드 데이터가 전부 여기 들어간다.
- RGW dataPool은 size(복제본 수)=2, min_size=1로 의도적으로 낮췄다(연구용 데이터라 손실 감수). min_size는 이 값 미만으로 살아있는 복제본이 줄면 쓰기 자체를 막는 안전장치다. 다른 노드 장애와 겹치면 실제로 데이터가 날아갈 수 있다. 이 설정이 cephadm 재구축 과정에서 한 번 유실된 적이 있다 — [`07-1-ceph-storage.md`의 관련 알려진 이슈](07-1-ceph-storage.md#rgw-데이터-풀의-size2-결정이-재구축-과정에서-누락되기-쉽다) 참고.
- HEALTH_WARN(insecure key type 경고)은 무해하다. 다만 커널 6.8에서는 해소 불가하다(7.0+ 필요). 낮은 우선순위로 방치했다.

## 재현 방법

- 쓰기: `rados bench -p rbd-pool 30 write --no-cleanup`
- 읽기: `rados bench -p rbd-pool 30 seq` / `rados bench -p rbd-pool 30 rand`
- 네트워크 링크: 한쪽에서 `iperf3 -s`, 다른쪽에서 `iperf3 -c <서버 IP>`
- OSD 지연: `ceph osd perf`
- EC 프로필: `ceph osd erasure-code-profile set <이름> k=2 m=1 crush-failure-domain=host`
- EC 풀 생성: `ceph osd pool create <이름> erasure <프로필>` (RBD로 쓰려면 `allow_ec_overwrites true` + 별도 복제 메타데이터 풀 필요, RGW는 `buckets.data`를 EC로 미리 만들어두면 그대로 씀)
- RBD 랜덤쓰기 벤치: `rbd bench --io-type write --io-pattern rand --io-size 4K --io-total 200M <풀>/<이미지>`
- 소규모 오브젝트 순차 쓰기(로그 배치 패턴): `rados bench -p <풀> 20 write -b 65536 --no-cleanup`
- RADOS append: `rados -p <풀> append <오브젝트명> <파일>` (EC는 `allow_ec_overwrites true` 없이는 거부됨)

---

[← 이전: Ceph 스토리지](07-1-ceph-storage.md) · [다음: StarRocks 분석 엔진 →](08-1-starrocks-analytics.md)
