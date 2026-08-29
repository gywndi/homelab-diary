# Ceph 스토리지 벤치마크

설계는 [Ceph 스토리지](07-1-ceph-storage.md) 참고. 실사용 가능한 성능인지 스토리지/DB/OLAP 세 계층을 각각 측정했다.

## 핵심 결론

| 항목 | 결과 |
|---|---|
| Ceph 쓰기(`rados bench` — Ceph 자체 제공 성능 측정 도구, 4MB obj, 16 threads, rbd-pool) | 86 MB/s, 평균 지연 738ms |
| Ceph 순차/랜덤 읽기 | 161 MB/s, 평균 지연 388ms |
| 병목 원인 | 디스크가 아니라 **1GbE 네트워크**(3노드 전부 NIC 상한 1000Mb/s) |
| MySQL(`sysbench oltp_read_write` — 일반적인 온라인 트랜잭션 처리 패턴을 흉내낸 부하 테스트, 8 threads, 40만 행) 튜닝 전 | 125 TPS(초당 처리한 트랜잭션 수), 평균 지연 64ms |
| MySQL `innodb_flush_log_at_trx_commit=2` 튜닝 후 | **190.98 TPS(+52%)**, 평균 지연 41.87ms(-34%) |
| StarRocks 100만 행 로드 | ~3초 |
| StarRocks 집계 쿼리(COUNT/GROUP BY/범위 필터, 100만 행) | 전부 30ms 미만(CN 로컬 Data Cache 덕분) |

**설계 규칙**: 1GbE 위에서 매 트랜잭션 커밋마다 fsync를 강제하면 RBD 3-replica 전체 ack 대기가 매번 발생한다 — `innodb_flush_log_at_trx_commit=2`로 fsync를 1초 단위로 묶어야 한다(크래시 안전성 트레이드오프는 mysqld 크래시엔 안전, OS 크래시 시 최근 1초분 유실 가능). 개선하려면 디스크 교체는 의미 없고 NIC을 10GbE로 올리는 것만이 실질적 해법 — 지금 규모에선 문제없지만 트래픽이 커지면 이 지점이 먼저 막힌다.

StarRocks/shared-nothing vs shared-data 상세 벤치마크(CN 확장, FE 배치, 압축률, 페이지네이션)는 [StarRocks BMT](08-2-starrocks-analytics-bmt.md) 참고 — 이 문서는 Ceph 자체(RBD/RGW) 레이어만 다룬다.

## 병목 분석: 디스크가 아니라 1GbE 네트워크였다

하나씩 배제해서 좁혔다:
- 디스크 하드웨어: 3노드 전부 SSD/NVMe(회전형 없음) — 후보 제외
- OSD 자체 쓰기 지연: `ceph osd perf` 기준 commit/apply 지연 1~2ms — 후보 제외
- 네트워크 링크 상태: `iperf3`로 chan08↔chan09 실측 941Mbps, 재전송 0 — 링크 자체는 건강
- **네트워크 대역폭 상한: 3노드 전부 물리 NIC이 1GbE** — 이게 실제 병목

size=3 replication 쓰기는 클라이언트→primary OSD로 들어온 뒤 primary가 나머지 2개 replica로 다시 내보내야 완료 처리된다. primary 노드의 NIC 하나가 "받는 트래픽 + 내보내는 트래픽 ×2"를 전부 같은 1Gbps 파이프로 처리해야 해서, 원본 링크 속도(iperf3 실측 117MB/s)보다 실제 쓰기 처리량(86MB/s)이 낮고 지연도 커진다.

StarRocks 집계 쿼리가 Ceph 자체는 느린데도 30ms 미만인 건 CN의 로컬 Data Cache 덕분 — "콜드 데이터는 네트워크/Ceph 속도에 매여있고, 캐시된 데이터는 빠르다"는 shared-data 구조의 트레이드오프가 실측으로 확인됐다.

## MySQL 컷오버 후 발견한 문제 3건

- **`innodb_flush_log_at_trx_commit`을 2로 낮췄다.** 1GbE 병목 위에서 매 커밋마다 fsync를 강제하면 그 자체가 매번 RBD size=3 전체 ack 대기를 유발한다 — 위 "핵심 결론"의 재측정치로 효과 확인.
- **semi-sync 복제 잔재가 첫 커밋을 10초 가까이 멈추게 했다.** 물리 복사로 datadir을 옮길 때 `rpl_semi_sync_source_enabled=1`이 persisted variable(서버를 재시작해도 유지되는 MySQL 설정값)로 그대로 딸려와서, 레플리카는 이미 폐기했는데 소스는 여전히 레플리카의 ack(수신 확인)를 기다리는 상태였다. 첫 트랜잭션에서 10초 타임아웃 후 자동으로 async(비동기) 전환됐지만, 파드 재시작마다 재발할 잠재 위험이라 `UNINSTALL PLUGIN` + `RESET PERSIST`로 완전히 제거.
- **`externalTrafficPolicy`가 기본값 `Cluster`라 MySQL 호스트 기반 인증이 깨졌다(가장 심각).** `Cluster` 정책에서는 트래픽을 받은 노드와 파드가 있는 노드가 다르면 kube-proxy가 SNAT(요청의 출발지 IP를 자기 것으로 바꿔치기하는 것)을 하는데, 이때 MySQL이 보는 클라이언트 IP가 호스트 기반 grant(`user@'10.5.5.%'`처럼 "이 IP 대역에서 접속한 사용자만 허용"하는 권한 규칙)와 안 맞는 pod-CIDR 주소로 바뀌어 실서비스 DB 라우트가 전부 500 에러를 냈다. `externalTrafficPolicy: Local`로 바꿔서 해결(단일 replica라 가용성 영향 없음). **호스트 기반 MySQL 인증 + MetalLB LoadBalancer Service 조합에서는 `Local`이 필수.**

## 재측정 (설정 변경 후)

`innodb_flush_log_at_trx_commit=2` + semi-sync 제거 후 동일 `sysbench oltp_read_write`(8 threads, 40만 행):

| 지표 | 변경 전 | 변경 후 | 개선 |
|---|---|---|---|
| TPS | 125.29 | 190.98 | **+52%** |
| 평균 지연 | 63.80ms | 41.87ms | **-34%** |
| 95th 지연(전체 요청 중 95%가 이 시간 안에 끝남 — 가장 느린 5%를 뺀 사실상의 체감 최대 지연) | 137.35ms | 99.33ms | -28% |

## 남아있는 리스크

- Ceph usable 용량(재분할 후 약 700GiB대)을 RBD와 RGW가 통째로 나눠 쓴다 — MySQL(17G)+KVM+StarRocks 테스트 데이터가 전부 여기 들어간다.
- RGW dataPool은 size(복제본 수)=2/min_size(이 값 미만으로 살아있는 복제본이 줄면 쓰기 자체를 막는 안전장치)=1로 의도적으로 낮췄다(연구용 데이터라 손실 감수) — 다른 노드 장애와 겹치면 실제로 데이터가 날아갈 수 있다.
- HEALTH_WARN(insecure key type 경고)은 무해하지만 커널 6.8에서는 해소 불가(7.0+ 필요) — 낮은 우선순위로 방치.

## 재현 방법

- 쓰기: `rados bench -p rbd-pool 30 write --no-cleanup`
- 읽기: `rados bench -p rbd-pool 30 seq` / `rados bench -p rbd-pool 30 rand`
- 네트워크 링크: 한쪽에서 `iperf3 -s`, 다른쪽에서 `iperf3 -c <서버 IP>`
- OSD 지연: `ceph osd perf`
- MySQL: `sysbench oltp_read_write --tables=1 --table-size=400000 --threads=8 run`
