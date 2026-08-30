# Ceph 스토리지 벤치마크

[← 이전: Ceph 스토리지](07-1-ceph-storage.md) · [다음: StarRocks 분석 엔진 →](08-1-starrocks-analytics.md)

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

## 남아있는 리스크

- Ceph usable 용량(재분할 후 약 700GiB대)을 RBD와 RGW가 통째로 나눠 쓴다. MySQL(17G)+KVM 데이터와 RGW에 올라간 다른 워크로드 데이터가 전부 여기 들어간다.
- RGW dataPool은 size(복제본 수)=2, min_size=1로 의도적으로 낮췄다(연구용 데이터라 손실 감수). min_size는 이 값 미만으로 살아있는 복제본이 줄면 쓰기 자체를 막는 안전장치다. 다른 노드 장애와 겹치면 실제로 데이터가 날아갈 수 있다. 이 설정이 cephadm 재구축 과정에서 한 번 유실된 적이 있다 — [`07-1-ceph-storage.md`의 관련 알려진 이슈](07-1-ceph-storage.md#rgw-데이터-풀의-size2-결정이-재구축-과정에서-조용히-사라져-있었다) 참고.
- HEALTH_WARN(insecure key type 경고)은 무해하다. 다만 커널 6.8에서는 해소 불가하다(7.0+ 필요). 낮은 우선순위로 방치했다.

## 재현 방법

- 쓰기: `rados bench -p rbd-pool 30 write --no-cleanup`
- 읽기: `rados bench -p rbd-pool 30 seq` / `rados bench -p rbd-pool 30 rand`
- 네트워크 링크: 한쪽에서 `iperf3 -s`, 다른쪽에서 `iperf3 -c <서버 IP>`
- OSD 지연: `ceph osd perf`
