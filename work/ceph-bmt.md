# Ceph BMT (벤치마크)

> 이 문서는 초안이다. 검증까지 끝나면 `lessons/`로 옮겨 다듬는다. 설치 방법은 [설치](ceph-install.md), 배경은 [소개](ceph-intro.md) 참고.

BMT(벤치마크) 목적에 실제로 쓸 만한 성능인지 확인하기 위해 스토리지/DB/OLAP 세 계층을 각각 측정했다.

## 측정 결과

| 항목 | 결과 |
|---|---|
| Ceph 쓰기 (`rados bench`, 4MB obj, 16 threads, rbd-pool) | 86 MB/s, 평균 지연 738ms |
| Ceph 순차/랜덤 읽기 | 161 MB/s, 평균 지연 388ms |
| MySQL (`sysbench oltp_read_write`, 8 threads, 40만 행) — 튜닝 전 | 125 TPS, 평균 지연 64ms, 95th 137ms |
| MySQL — `innodb_flush_log_at_trx_commit=2` 튜닝 후 | **190.98 TPS**(+52%), 평균 지연 41.87ms(-34%), 95th 99.33ms(-28%) |
| StarRocks 100만 행 로드 | ~3초 |
| StarRocks 집계 쿼리(COUNT/GROUP BY/범위 필터, 100만 행) | 전부 30ms 미만 |

StarRocks/shared-nothing vs shared-data 상세 벤치마크는 [StarRocks BMT](starrocks-bmt.md) 참고 — 이 문서는 Ceph 자체(RBD/RGW) 레이어의 성능만 다룬다.

## 병목 분석: 디스크가 아니라 1GbE 네트워크였다

하나씩 배제해서 좁혔다:
- 디스크 하드웨어: 3노드 전부 SSD/NVMe(회전형 없음) — 후보에서 제외
- OSD 자체 쓰기 지연: `ceph osd perf` 기준 commit/apply 지연 1~2ms — 매우 빠름, 후보에서 제외
- 네트워크 링크 상태: `iperf3`로 chan08↔chan09 실측 941Mbps, 재전송 0 — 링크 자체는 완전 건강
- **네트워크 대역폭 상한: 3노드 전부 물리 NIC이 1GbE(1000Mb/s)** — 이게 진짜 병목

size=3 replication 쓰기는 클라이언트→primary OSD로 들어온 뒤 primary가 나머지 2개 replica로 다시 내보내야 완료 처리된다. primary 노드의 NIC 하나가 "받는 트래픽 + 내보내는 트래픽 ×2"를 전부 같은 1Gbps 파이프로 처리해야 해서, 원본 링크 속도(iperf3 실측 117MB/s)보다 실제 쓰기 처리량(86MB/s)이 낮고 지연도 커지는 게 정확히 설명된다.

StarRocks 집계 쿼리가 Ceph 자체는 느린데도 30ms 미만으로 빠른 건 CN의 로컬 Data Cache 덕분 — "콜드 데이터는 네트워크/Ceph 속도에 매여있고, 캐시된 데이터는 빠르다"는 shared-data 구조의 트레이드오프가 실측으로 확인됐다.

개선하려면 디스크 교체는 의미가 없고, NIC을 10GbE로 올리는 것만이 실질적인 해법이다. 지금 BMT 규모에서는 문제없지만 실 트래픽이 커지면 이 지점이 먼저 막힌다.

## MySQL 컷오버 이후 발견/수정한 문제

- **`innodb_flush_log_at_trx_commit`을 2로 낮췄다.** 1GbE 병목 위에서 매 트랜잭션 커밋마다 fsync를 강제하면 그 자체가 매번 네트워크 왕복(RBD size=3, 전체 복제본 ack 대기)을 유발한다. 2로 바꾸면 fsync가 1초에 한 번으로 묶여서 커밋 지연이 크게 줄어든다 — mysqld 크래시엔 안전하고, OS/서버 자체가 죽는 경우에만 최근 1초 데이터를 잃을 수 있는 정도의 위험만 감수.
- **semi-sync 복제 잔재가 첫 커밋을 10초 가까이 멈추게 하고 있었다.** 물리 복사로 datadir을 옮길 때 `rpl_semi_sync_source_enabled=1`이 persisted variable로 그대로 딸려왔다 — 레플리카는 이미 폐기했는데 소스는 여전히 "레플리카의 ack를 기다리는" 상태였다. 컷오버 직후 첫 트랜잭션에서 한 번 10초 타임아웃을 맞고 자동으로 async 전환됐지만, 파드가 재시작될 때마다 이 스톨이 재발할 잠재 위험이었다 — `UNINSTALL PLUGIN` + `RESET PERSIST`로 완전히 제거.
- **가장 심각했던 문제: `externalTrafficPolicy`가 기본값 `Cluster`라 MySQL 호스트 기반 인증이 깨져 있었다.** `Cluster` 정책에서는 트래픽이 받은 노드와 실제 파드가 있는 노드가 다르면 kube-proxy가 SNAT을 하는데, 이때 MySQL이 보는 클라이언트 IP가 호스트 기반 grant(`user@'10.5.5.%'`)와 안 맞는 pod-CIDR 주소(`10.244.0.0`)로 바뀌어버렸다 — 실제 프로덕션 서비스(`stock-crawler-api`)의 DB 라우트가 전부 500 에러를 내는 사고로 이어졌다. `externalTrafficPolicy: Local`로 바꿔서 원본 클라이언트 IP를 보존하도록 해결(단일 replica라 가용성 영향 없음). **호스트 기반 MySQL 인증을 쓰는 상태에서 MetalLB LoadBalancer Service로 노출할 때는 `externalTrafficPolicy: Local`이 필수.**

## 설정 변경 전/후 재측정

`innodb_flush_log_at_trx_commit=2` 적용 + semi-sync 제거 후 동일한 `sysbench oltp_read_write`(8 threads, 40만 행)로 재측정:

| 지표 | 변경 전 | 변경 후 | 개선 |
|---|---|---|---|
| TPS | 125.29 | 190.98 | **+52%** |
| 평균 지연 | 63.80ms | 41.87ms | **-34%** |
| 95th 지연 | 137.35ms | 99.33ms | -28% |

예상대로 매 커밋 fsync가 1GbE 병목 위에서 상당한 비용이었다는 게 실측으로 확인됐다 — fsync 하나하나가 RBD 복제 왕복(size=3, 전체 복제본 ack 대기)을 유발하는데, 이걸 1초 단위로 묶으니 커밋 경로에서 네트워크 왕복 횟수 자체가 줄어든 것.

## 남아있는 리스크

- **Ceph usable 용량(재분할 후 약 700GiB대)을 RBD와 RGW가 통째로 나눠 쓴다.** MySQL(17G)+KVM+StarRocks 테스트 데이터가 전부 여기 들어간다.
- **RGW dataPool은 size=2/min_size=1로 의도적으로 낮췄다** — 연구용 데이터라 손실을 감수하기로 한 결정이지 버그는 아니지만, 다른 노드 장애와 겹치면 실제로 데이터가 날아갈 수 있다.
- HEALTH_WARN(insecure key type 경고)은 무해하지만 커널 6.8에서는 해소 불가(7.0+ 필요) — 낮은 우선순위로 그냥 둔다.
