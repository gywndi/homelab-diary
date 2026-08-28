# Ceph 스토리지 레이어 도입 (진행 중)

> 이 문서는 초안이다. 검증까지 끝나면 `lessons/`로 옮겨 다듬는다. 2026-08-27 기준: Rook-Ceph 클러스터(mon/mgr/osd) + RBD StorageClass + RGW(S3, VIP 노출) + MySQL을 RBD PVC 기반 k8s 워크로드로 컷오버까지 전부 완료. 남은 건 KVM libvirt를 RBD로 전환하는 것과 StarRocks 연동뿐.

StarRocks 컴퓨팅/스토리지 분리 구성을 테스트해보기 전에, 그 전제가 되는 스토리지 레이어를 Ceph로 통일하기로 했다. 새 장비를 들이지 않고 기존 3노드(chan08/chan09/llm001)를 재구성하는 것만으로 진행한다.

## 목적

StarRocks의 shared-data 모드(컴퓨팅/스토리지 분리)는 컴퓨트 노드가 로컬 디스크가 아니라 S3 호환 오브젝트 스토리지를 보게 만드는 구조다. 이 오브젝트 스토리지를 마련하는 김에, 같은 노드에서 이미 돌고 있는 KVM VM 디스크와 MySQL 데이터도 같은 스토리지 계층으로 옮겨서 노드 장애와 데이터를 분리시키는 것이 이번 작업의 목표다.

## 설계 결정

- **새 장비 없이 기존 3노드 재구성.** Ceph는 3-replica가 기본값인데 마침 물리 노드가 정확히 3대라 딱 맞는다.
- **RBD(블록)와 RGW(오브젝트)의 역할을 분리했다.** 처음엔 "Ceph 하나로 다 해결"이라고 뭉뚱그려 생각했는데, 실제 접근 패턴이 셋으로 갈렸다: KVM VM 디스크와 MySQL 데이터는 항상 한 프로세스만 배타적으로 쓰는 블록 데이터(RBD), StarRocks는 S3 API로 접근하는 오브젝트(RGW). 이 둘은 Ceph 안에서 서로 다른 컴포넌트가 서빙한다.
- **CephFS(MDS)는 배제했다.** 여러 파드가 동시에 같은 파일을 읽고 써야 하는 워크로드(RWX)가 지금은 없다. MDS 데몬을 상시로 띄우는 비용을 32G/노드 예산에서 정당화할 근거가 없어서, RWX가 필요해지면 그때 NAS(NFS)로 커버하기로 하고 지금은 뺐다.
- **NAS를 OSD 백엔드로 쓰지 않는다.** 네트워크 스토리지(NAS) 위에 또 네트워크 스토리지(Ceph)를 얹으면 지연/장애 시나리오가 한 겹 더 지저분해진다. NAS의 역할은 백업 타깃과, 나중에 RWX가 필요해질 때의 NFS StorageClass로 좁혔다.
- **MySQL을 semi-sync 복제 대신 "shared-disk failover cluster" 패턴으로 재구성한다.** 단일 mysqld 인스턴스가 k8s StatefulSet + Ceph RBD PVC(RWO) 위에서 돌고, 데이터 내구성은 애플리케이션 레벨 복제가 아니라 Ceph 3-replica가 담당한다. 노드가 죽으면 k8s가 다른 노드로 파드를 재스케줄하면서 RBD PVC가 그대로 따라간다. 이때 RBD의 exclusive-lock이 핵심 안전장치다 — 두 노드가 동시에 같은 datadir을 잡으려 해도 락에 막혀 안전하게 실패한다(split-brain 방지).
- **"MySQL은 컨테이너/k8s 미사용"이었던 Stage 1 결정을 뒤집었다.** k8s가 RWO PVC 재부착과 파드 재스케줄을 이미 구현해두고 있어서, 같은 결과(노드 장애 시 다른 곳에서 단일 인스턴스 재기동)를 호스트 레벨 스크립트(rbd map + mount + VIP 수동 전환)로 직접 짜는 것보다 훨씬 적은 노력으로 얻을 수 있다고 판단했다.
- **KVM도 같은 이유로 RBD 위에 둔다.** libvirt는 RBD를 네이티브 스토리지 풀로 지원한다(OpenStack Cinder/Nova가 쓰는 것과 같은 방식). VM 디스크를 로컬 qcow2 파일 대신 RBD 이미지로 두면, 노드 장애 시 다른 노드에서 같은 이미지를 가리키는 도메인을 재정의해 기동할 수 있다. 다만 이건 k8s가 대신 해주지 않는 수동 절차다 — libvirt 도메인 XML을 노드 간에 자동으로 동기화해주는 장치가 없기 때문.
- **hostNetwork는 필수다.** libvirt/QEMU는 k8s pod network 밖(호스트)에서 도는 프로세스라, Ceph mon/OSD가 pod IP에만 붙어 있으면 접근할 수 없다. CephCluster를 hostNetwork로 배포해서 노드 IP로 직접 붙게 한다.
- **기존 MySQL VIP(`10.5.5.4`)를 재사용한다.** 새 k8s Service를 MetalLB로 같은 IP에 노출하면 애플리케이션(stock-crawler-api 등)이 접속 주소를 바꾸지 않아도 된다.

## 아키텍처

```mermaid
flowchart TB
    subgraph C08["chan08"]
        OSD08["Ceph OSD<br/>(구 /data 디스크)"]
    end
    subgraph C09["chan09"]
        OSD09["Ceph OSD<br/>(구 /data 디스크)"]
    end
    subgraph C10["llm001"]
        OSD10["Ceph OSD<br/>(구 /data 디스크)"]
    end

    OSD08 <-. 3-replica .-> OSD09
    OSD09 <-. 3-replica .-> OSD10
    OSD10 <-. 3-replica .-> OSD08

    RBD["RBD pool<br/>(블록, 단일 접근)"]
    RGW["RGW<br/>(S3 API)"]

    OSD08 & OSD09 & OSD10 --> RBD
    OSD08 & OSD09 & OSD10 --> RGW

    RBD --> KVM["KVM VM 디스크<br/>(호스트에서 직접 rbd map)"]
    RBD --> MYSQL["MySQL StatefulSet<br/>(RWO PVC, 단일 인스턴스)"]
    RGW --> SR["StarRocks CN<br/>(shared-data)"]
```

## 실행 중 발견한 이슈

- **datadir을 옮겨도 binlog는 안 따라온다.** `datadir`을 `/data/mysql` → `/home/mysql`로 바꿨는데, `/data`가 계속 busy(umount 불가)였다. 원인은 별도 튜닝 설정 파일에 `log_bin = /data/mysql/mysql-bin`이 절대경로로 하드코딩되어 있던 것 — datadir 설정과 별개라 안 바뀌고 계속 옛 경로에 쓰고 있었다. `SHOW VARIABLES LIKE '%dir%'`류가 아니라 각 설정 파일에서 절대경로를 쓰는 항목(log_bin, innodb_undo_directory 등)을 따로 확인해야 한다.
- **AppArmor 로컬 오버라이드도 같이 옮겨야 한다.** Ubuntu MySQL 패키지는 `/etc/apparmor.d/local/usr.sbin.mysqld`에 datadir 경로를 화이트리스트로 걸어둔다. 새 경로를 추가하지 않으면 mysqld가 파일 접근을 거부당하며 죽는다.
- **되돌릴 수 없는 원격 명령은 Claude Code 자동 모드 분류기가 막는다.** `wipefs` 같은 명령은 세션 권한으로 승인해도 별도 분류기가 한 번 더 막아서, 프로젝트 로컬 설정(`.claude/settings.local.json`)에 해당 호스트로의 ssh/scp를 허용 규칙으로 추가해야 진행할 수 있었다.
- **Rook 1.20부터 CSI 드라이버가 별도 오퍼레이터로 분리됐다.** `crds.yaml` → `common.yaml` → `operator.yaml` 순서만 알고 있었는데, 실제로는 그 사이에 `csi-operator.yaml`(ceph-csi-operator의 `OperatorConfig`/`Driver` CRD)을 먼저 적용해야 한다. 빠뜨리면 "no matches for kind Driver/OperatorConfig" 에러가 난다. 공식 quickstart를 다시 확인하고서야 알았다.
- **operator reconcile이 에러 없이 멈추는 일이 반복됐다.** CephCluster CR을 두 번 apply했을 때(리소스 버전 충돌 `the object has been modified` 발생 이후 mon-a만 뜨고 멈춤), 그리고 CephBlockPool 생성 때도(로그에 "successfully configured" 이벤트까지 찍히는데 실제 풀은 안 생기고 그대로 멈춤) 똑같은 패턴이 나왔다 — 에러 로그 없이 조용히 진행이 끊긴다. 두 번 다 `kubectl rollout restart deployment/rook-ceph-operator`로 reconcile을 처음부터 다시 돌리니 정상 진행됐다. Rook 1.20 operator의 재현되는 특성으로 보이니, 진행이 몇 분 이상 안 보이면 우선 operator 재시작부터 시도할 것.
- **`kubectl wait`는 매칭되는 리소스가 하나도 없으면 기다리지 않고 즉시 에러를 낸다.** mon/osd 파드가 아직 생성되기 전에 `kubectl wait -l app=...`를 걸면 "no matching resources found"로 바로 실패한다 — 파드가 생기는 것부터 폴링한 뒤에 `wait`를 걸어야 한다.
- **RGW가 계속 멈춘 진짜 원인은 방화벽의 same-node hairpin 누락이었다.** k8s API 서버 때(`lessons/06-llm-gpu-node.md`)와 정확히 같은 유형의 버그를 Ceph 포트에서도 그대로 반복했다 — 같은 노드(llm001) 안에서 pod network 파드(toolbox 등)가 hostNetwork Ceph 데몬(osd.2)에 접근할 때 소스 IP가 `10.5.5.0/24`가 아니라 pod CIDR(`10.244.0.0/16`)이라 방화벽 규칙에 안 걸려 TCP 연결 자체가 막혔다. `rados`/`radosgw-admin` 명령이 에러 메시지 없이 그냥 멈춰서(수 분씩 응답 대기) 처음엔 Rook 자체 버그로 오인했다 — `ceph tell osd.<N> version`으로 개별 데몬 응답성을 하나씩 확인하면서 특정 OSD 하나만 응답이 없는 걸로 좁혀야 찾을 수 있었다. 방화벽 스크립트에 pod CIDR 소스 예외 규칙을 추가해서 해결(3노드 모두 재적용 필요).
- **CephObjectStore의 gateway.service는 Service `type`을 지정할 수 없다.** annotations/labels만 지원해서, Rook이 소유한 `rook-ceph-rgw-*` Service를 `kubectl patch`로 LoadBalancer로 바꿔도 operator가 reconcile할 때마다 ClusterIP로 도로 바뀐다(MetalLB가 VIP를 할당해도 몇 초 뒤 사라짐 — 처음엔 "MetalLB가 불안정하다"고 오인했는데, 실제로는 Service 자체가 계속 리셋되고 있었다). Rook 소유 Service는 그대로 두고, 같은 파드 라벨을 셀렉터로 쓰는 별도 Service를 만들어 그것만 LoadBalancer로 노출하는 방식으로 해결.
- **CephObjectStore 삭제가 자기 자신을 참조하는 순환으로 멈췄다.** 방화벽 문제로 실패했던 시도들이 `.rgw.root`에 realm/zonegroup/zone은 만들어졌지만 period가 없는 반쪽 상태를 남겼는데, 이 CR을 지우려 하면 finalizer가 "버킷이 있는지" 확인하려고 RGW 자신의 HTTP API를 호출한다 — 근데 그 RGW는 애초에 뜬 적이 없으니 연결 거부로 finalizer가 영원히 못 끝난다. 버킷이 존재한 적이 없다는 걸 확인한 뒤 finalizer를 강제로 비우고, 남은 rados 오브젝트/풀은 직접 정리한 뒤 처음부터 재생성했다.

## 중간 점검 (2026-08-27) — MySQL 이전 전 남아있던 리스크 (현재 대부분 해소)

- **MySQL 단일 장애점 창** — chan09 레플리카 폐기 후 새 워크로드 컷오버 전까지 존재했던 구간. → RBD PVC 컷오버 완료로 해소(아래 참고). 다만 지금도 replica는 1개뿐이라 "애플리케이션 레벨 이중화 없음"은 여전 — 내구성은 Ceph 3-replica가, 재기동은 k8s 재스케줄이 담당하는 구조로 대체됐을 뿐.
- **Rook operator의 reconcile-stall이 세 번(mon, CephBlockPool, CephObjectStore) 재현됐는데 근본 원인은 못 찾았다.** 매번 "로그에 에러 없이 조용히 멈춤 → operator 재시작으로 해결"이었다. MySQL PVC 생성 때는 재현되지 않고 바로 Bound됐다 — 재현 조건이 명확하진 않다.
- **Ceph usable 용량(821GiB)을 RBD와 RGW가 통째로 나눠 쓴다.** MySQL(17G)+KVM+StarRocks 테스트 데이터가 전부 여기 들어간다. StarRocks 데이터셋 규모에 따라 여유가 빠듯해질 수 있다.
- **RGW dataPool은 size=2/min_size=1로 의도적으로 낮췄다** — 연구용 데이터라 손실을 감수하기로 한 결정이지 버그는 아니지만, 다른 노드 장애와 겹치면 실제로 데이터가 날아갈 수 있다는 걸 계속 염두에 둘 것.
- **VIP(`10.5.5.6`, `10.5.5.4`)가 라우터 DHCP 임대 대역과 안 겹치는지 아직 미확인** — `internal/ip-inventory.md`에 이미 있던 TODO 항목이고 이번 작업으로 새로 생긴 문제는 아니다.
- HEALTH_WARN(insecure key type 경고)은 무해하지만 커널 6.8에서는 해소 불가(7.0+ 필요) — 낮은 우선순위로 그냥 둔다.

## 성능 측정 및 병목 분석 (2026-08-28)

BMT 목적에 실제로 쓸 만한 성능인지 확인하기 위해 세 계층을 각각 측정했다.

| 항목 | 결과 |
|---|---|
| Ceph 쓰기 (`rados bench`, 4MB obj, 16 threads, rbd-pool) | 86 MB/s, 평균 지연 738ms |
| Ceph 순차/랜덤 읽기 | 161 MB/s, 평균 지연 388ms |
| MySQL (`sysbench oltp_read_write`, 8 threads, 40만 행) | 125 TPS, 평균 지연 64ms, 95th 137ms |
| StarRocks 100만 행 로드 | ~3초 |
| StarRocks 집계 쿼리 (COUNT/GROUP BY/범위 필터, 100만 행) | 전부 30ms 미만 (서버 타임스탬프로 측정, 클라이언트 파드 기동 오버헤드 제외) |

**병목은 디스크가 아니라 1GbE 네트워크였다.** 하나씩 배제해서 좁혔다:
- 디스크 하드웨어: 3노드 전부 SSD/NVMe(회전형 없음) — 후보에서 제외
- OSD 자체 쓰기 지연: `ceph osd perf` 기준 commit/apply 지연 1~2ms — 매우 빠름, 후보에서 제외
- 네트워크 링크 상태: `iperf3`로 chan08↔chan09 실측 941Mbps, 재전송 0 — 링크 자체는 완전 건강
- **네트워크 대역폭 상한: 3노드 전부 물리 NIC이 1GbE(1000Mb/s)** — 이게 진짜 병목

size=3 replication 쓰기는 클라이언트→primary OSD로 들어온 뒤 primary가 나머지 2개 replica로 다시 내보내야 완료 처리된다. primary 노드의 NIC 하나가 "받는 트래픽 + 내보내는 트래픽 ×2"를 전부 같은 1Gbps 파이프로 처리해야 해서, 원본 링크 속도(iperf3 실측 117MB/s)보다 실제 쓰기 처리량(86MB/s)이 낮고 지연도 커지는 게 정확히 설명된다.

StarRocks 집계 쿼리가 Ceph 자체는 느린데도 30ms 미만으로 빠른 건 CN의 로컬 데이터 캐시 덕분 — "콜드 데이터는 네트워크/Ceph 속도에 매여있고, 캐시된 데이터는 빠르다"는 shared-data 구조의 트레이드오프가 실측으로 확인됐다.

## 컷오버 이후 발견/수정한 문제 (2026-08-28)

- **`innodb_flush_log_at_trx_commit`을 2로 낮췄다.** 1GbE 병목 위에서 매 트랜잭션 커밋마다 fsync를 강제하면 그 자체가 매번 네트워크 왕복을 유발한다. 2로 바꾸면 fsync가 1초에 한 번으로 묶여서 커밋 지연이 크게 줄어든다 — mysqld 크래시엔 안전하고, OS/서버 자체가 죽는 경우에만 최근 1초 데이터를 잃을 수 있는 정도의 위험만 감수. 런타임 적용 + ConfigMap에도 영구 반영.
- **semi-sync 복제 잔재가 첫 커밋을 10초 가까이 멈추게 하고 있었다.** chan08에서 물리 복사로 datadir을 옮길 때 `rpl_semi_sync_source_enabled=1`이 persisted variable로 그대로 딸려왔다 — 레플리카(chan09)는 이미 폐기했는데 소스는 여전히 "레플리카의 ack를 기다리는" 상태였던 것. 실제로는 컷오버 직후 첫 트랜잭션에서 딱 한 번(`Rpl_semi_sync_source_no_times=1`) 10초 타임아웃을 맞고 자동으로 async로 전환돼 그 이후 1440건은 정상 처리됐지만, **파드가 재시작될 때마다 이 10초 스톨이 다시 발생할 수 있는 잠재 위험**이었다. `UNINSTALL PLUGIN` + `RESET PERSIST`로 완전히 제거.
- **가장 심각했던 문제: `externalTrafficPolicy`가 기본값 `Cluster`라 MySQL 호스트 기반 인증이 깨져 있었다.** 컷오버 직후부터 `stock-crawler-api`(맥 스튜디오에서 도커로 운영 중인 실제 서비스)의 DB 관련 API가 전부 500 에러를 내고 있었다 — `ext-stock-abcyon` ingress 프록시 로그를 보고서야 발견했다(`/api/collections/*/status`는 200인데 `/api/stocks`, `/auth/login` 등 DB를 만지는 라우트만 500). `Cluster` 정책에서는 트래픽이 받은 노드와 실제 파드가 있는 노드가 다르면 kube-proxy가 SNAT을 하는데, 이때 MySQL이 보는 클라이언트 IP가 `stock@'10.5.5.%'` 같은 호스트 기반 grant와 안 맞는 이상한 주소(`10.244.0.0`)로 바뀌어버렸다. `externalTrafficPolicy: Local`로 바꿔서 원본 클라이언트 IP를 보존하도록 해결 — 단일 replica라 이 정책으로 바꿔도 가용성엔 영향 없음. **호스트 기반 MySQL 인증을 쓰는 상태에서 MetalLB LoadBalancer Service로 노출할 때는 `externalTrafficPolicy: Local`이 필수라는 걸 배웠다** — 컷오버 스크립트(`11-mysql-vip-cutover.sh`)에 반영해야 함.

개선하려면 디스크 교체는 의미가 없고, NIC을 10GbE로 올리는 것만이 실질적인 해법이다. 지금 BMT 규모에서는 문제없지만 실 트래픽이 커지면 이 지점이 먼저 막힌다.

## 설정 변경 후 재측정 (2026-08-28)

`innodb_flush_log_at_trx_commit=2` 적용 + semi-sync 제거 후 동일한 `sysbench oltp_read_write`(8 threads, 40만 행)로 재측정:

| 지표 | 변경 전 | 변경 후 | 개선 |
|---|---|---|---|
| TPS | 125.29 | 190.98 | **+52%** |
| 평균 지연 | 63.80ms | 41.87ms | **-34%** |
| 95th 지연 | 137.35ms | 99.33ms | -28% |

예상대로 매 커밋 fsync가 1GbE 병목 위에서 상당한 비용이었다는 게 실측으로 확인됐다 — fsync 하나하나가 RBD 복제 왕복(size=3, 전체 복제본 ack 대기)을 유발하는데, 이걸 1초 단위로 묶으니 커밋 경로에서 그 네트워크 왕복 횟수 자체가 줄어든 것.

## 진행 상태

- [x] **MySQL/디스크 정리 완료 (2026-08-27)** — chan08은 mysqldump 안전 백업 후, datadir을 물리 복사(rsync)로 `/data`에서 `/home`으로 영구 이전(다운타임 최소화, VIP 영향 없음 확인). chan09(레플리카)는 폐기 전제로 mysqld만 중지. 3노드 `/data` 모두 wipefs로 raw 상태 전환 완료
- [x] **Rook-Ceph 클러스터 배포 완료 (2026-08-27)** — mon 3(quorum a,b,c) + mgr 1 + OSD 3(chan08/chan09/llm001, 총 2.5TiB) 모두 정상. `HEALTH_WARN`은 insecure key type 경고뿐(커널 6.8이라 legacy AES 키 사용 — 의도된 설정). 실사용 가능 용량은 `ceph df` 기준 약 821GiB(3-replica 반영, llm001 디스크가 작아 병목)
- [x] **RBD pool + StorageClass 생성 완료 (2026-08-27)** — `rbd-pool`(size=3/min_size=2), exclusive-lock 포함
- [x] **RGW(오브젝트 스토어) 생성 + VIP 노출 완료 (2026-08-27)** — dataPool은 연구용이라 용량 우선으로 size=2/min_size=1로 낮춤(metadataPool은 3 유지), VIP `10.5.5.6:7480`에서 정상 응답 확인
- [x] **MySQL을 RBD PVC 기반 k8s 워크로드로 컷오버 완료 (2026-08-27)** — `mysql` 네임스페이스에 Deployment(replicas=1, Recreate 전략) + 30Gi RBD PVC로 재배포. StatefulSet 대신 Deployment+Recreate를 쓴 이유는 단일 인스턴스라 StatefulSet의 순번 관리가 실익이 없어서. 데이터는 chan08에서 mysqld를 내리고 `tar` 스트림으로 임시 파드에 복사(17G, 약 5분) 후 이관. VIP `10.5.5.4`는 keepalived를 내리고 MetalLB로 같은 IP를 재할당해 애플리케이션 재설정 없이 유지. **총 다운타임 약 6분 38초**(21:38:12~21:44:50). 기존 keepalived/native mysql은 `systemctl disable`만 해두고 데이터·설정은 롤백 안전망으로 보존 중(완전 제거는 안정성 확인 후 별도 진행)
- [ ] libvirt storage pool을 rbd 타입으로 재정의 (KVM은 나중으로 미룸)
- [x] **StarRocks shared-data 배포 완료 (2026-08-27)** — RGW 엔드포인트 연동, end-to-end 검증까지 완료. 상세는 [StarRocks shared-data 배포](starrocks-shared-data.md) 참고
- [x] **디스크를 Ceph(고정 300G) + XFS(나머지)로 재분할 완료 (2026-08-28)** — shared-nothing StarRocks(BE) 테스트를 위한 로컬 저장소 확보. 상세는 아래 참고

## 디스크 재분할: Ceph 고정 300G + XFS (2026-08-28)

StarRocks는 shared-data(FE+CN, 우리가 이미 배포한 것) 말고 전통적인 shared-nothing(FE+BE, 로컬 디스크) 모드도 지원한다 — 이걸 테스트해보기 위해 각 노드 디스크를 둘로 나눴다: Ceph OSD는 노드마다 고정 300G로 맞추고, 나머지는 XFS로 포맷해 향후 BE 로컬 스토리지로 쓴다.

### 노드별 결과

| 노드 | Ceph OSD | XFS(BE용) |
|---|---|---|
| chan08 | osd.3, `/dev/sda1` 279G | `/dev/sda2` 652G → `/mnt/starrocks-be` |
| chan09 | osd.0, `/dev/sda1` 279G | `/dev/sda2` 652G → `/mnt/starrocks-be` |
| llm001 | osd.1, `/dev/nvme0n1p3` 280G | `/dev/nvme0n1p4` 451G → `/mnt/starrocks-be` |

llm001은 OS와 같은 물리 디스크(GPT)를 쓰고 있어서, 기존 p3(730.5G, Ceph OSD)만 삭제 후 재생성(p3=300G, p4=나머지)했다 — p1(EFI)/p2(root)는 전혀 건드리지 않았다. p3가 디스크의 마지막 파티션이었기 때문에 안전하게 가능했다.

### 진행 순서 (한 노드씩, 안전 우선)

각 노드마다: `ceph osd out` → PG remapping이 `active+clean`으로 안정화될 때까지 대기(misplaced는 무해, degraded/peering이 없어야 함) → deployment 삭제 + `ceph osd purge` → 디스크 재파티션 → 새 파티션 준비 → operator 재시작으로 재프로비저닝 → 전체 재분산이 끝나 281개 PG 전부 `active+clean`이 될 때까지 대기 → 다음 노드로.

시작 전에 MySQL 전체 백업을 새로 떴다(직전 백업이 하루 지나 있었음). 3노드 모두 size=3(RBD)/size=2(RGW) 풀이 매 순간 min_size 이상을 유지한 채 진행해서 데이터 손실 없이 완료했다.

### 겪은 문제: BlueStore 중복 레이블이 여러 위치에 흩어져 있다

chan08에서 처음엔 디스크 앞/뒤 200MB만 `dd`로 지우고 재파티션했는데, 새로 만든(더 작은) 파티션에 Rook이 OSD를 새로 만들지 않고 "기존 OSD를 확장(expand-bluefs)"하려다 계속 크래시했다 — `ceph-bluestore-tool show-label`로 직접 확인해보니, BlueStore는 원본 디스크 크기(931GB) 기준으로 레이블을 **1GB, 10GB, 107GB 지점**에 중복 저장해두고 있었다. 200MB만 지운 걸로는 이 레이블들을 전혀 건드리지 못했던 것.

해결: 새 파티션의 앞 **110GB를 통째로 `dd`로 제로화**해서 모든 중복 레이블 위치를 확실히 지웠다. chan09/llm001은 처음부터 이 방식을 적용해서 같은 문제를 겪지 않았다.

부수적으로 두 가지 더 배웠다:
- Rook의 osd-prepare Job은 디바이스 구성이 안 바뀐 것처럼 보이면(디바이스 이름이 같으면) 재실행을 스킵한다 — 강제로 다시 돌리려면 완료된 Job을 직접 삭제해야 한다.
- 이전에 실패했거나 삭제한 OSD의 Deployment가 operator 재시작 때마다 유령처럼 되살아나는 경우가 있었다(`CrashLoopBackOff`/`Init:Error` 상태로) — Ceph 쪽에 이미 없는 OSD인데 k8s Deployment 오브젝트만 남아있던 것. 매번 `kubectl delete deployment`로 정리해야 했다.

### 결과

재분할 후 raw 용량은 이전 2.5TiB에서 838GiB로 줄었지만(의도한 트레이드오프), 3노드를 동일 크기(300G)로 맞추면서 OSD별 사용률/PG 분산이 거의 완벽하게 균등해졌다(`ceph osd df` 기준 VAR 1.00/1.00, STDDEV 0.01) — 이전엔 노드마다 디스크 크기가 달라서(932G/932G/730G) 약간의 불균형이 있었는데 오히려 개선됐다.

## 스크립트 목록

- 방화벽: [`00-open-ceph-firewall-ports.sh`](../scripts/07-ceph-storage/00-open-ceph-firewall-ports.sh) — 3노드 모두에서 실행, hostNetwork용 mon/osd/mgr/RGW 포트 개방
- operator: [`01-install-rook-operator.sh`](../scripts/07-ceph-storage/01-install-rook-operator.sh) — Rook CRD/operator 설치 (v1.20.6)
- 클러스터: [`02-apply-cluster.sh`](../scripts/07-ceph-storage/02-apply-cluster.sh) + [`02-cluster.yaml`](../scripts/07-ceph-storage/02-cluster.yaml) — CephCluster 생성, 노드별 디바이스 명시(`chan08`/`chan09`=`sda1`, `llm001`=`nvme0n1p3`)
- 블록 스토리지: [`03-apply-storageclass.sh`](../scripts/07-ceph-storage/03-apply-storageclass.sh) + [`03-storageclass.yaml`](../scripts/07-ceph-storage/03-storageclass.yaml) — RBD 풀(3-replica) + StorageClass, exclusive-lock 포함
- 오브젝트 스토리지: [`04-apply-objectstore.sh`](../scripts/07-ceph-storage/04-apply-objectstore.sh) + [`04-objectstore.yaml`](../scripts/07-ceph-storage/04-objectstore.yaml) — RGW + MetalLB VIP 노출
- MySQL 백업: [`05-backup-mysql.sh`](../scripts/07-ceph-storage/05-backup-mysql.sh) — 전체 mysqldump (안전망)
- MySQL 이전(임시): [`06-relocate-mysql-datadir.sh`](../scripts/07-ceph-storage/06-relocate-mysql-datadir.sh) — datadir을 `/data`→`/home`으로 물리 복사 이전 (AppArmor/log_bin 경로 수정 포함). k8s 컷오버 전 임시 단계였음
- 디스크 wipe: [`07-wipe-data-disk.sh`](../scripts/07-ceph-storage/07-wipe-data-disk.sh) — `/data`를 raw 상태로 전환
- MySQL k8s 리소스: [`08-mysql-configmap-pvc.yaml`](../scripts/07-ceph-storage/08-mysql-configmap-pvc.yaml) — 네임스페이스/ConfigMap/RBD PVC(30Gi)
- MySQL 데이터 이전: [`09-mysql-migrate-data.sh`](../scripts/07-ceph-storage/09-mysql-migrate-data.sh) — 원본 mysqld 정지 후 tar 스트림으로 PVC에 복사(다운타임 유발 구간)
- MySQL 배포: [`10-mysql-deploy.yaml`](../scripts/07-ceph-storage/10-mysql-deploy.yaml) — Deployment(replicas=1, Recreate) + Service
- MySQL VIP 컷오버: [`11-mysql-vip-cutover.sh`](../scripts/07-ceph-storage/11-mysql-vip-cutover.sh) — keepalived 중지 → MetalLB로 같은 VIP 재할당
- 디스크 재분할: [`12-resplit-osd-disk.sh`](../scripts/07-ceph-storage/12-resplit-osd-disk.sh) — 전용 데이터 디스크(chan08/chan09 sda 패턴)를 Ceph 고정 크기 + XFS로 재분할, BlueStore 중복 레이블 제거를 위한 110GB 제로화 포함. llm001처럼 OS와 디스크를 공유하는 경우는 이 스크립트 대신 수동으로 대상 파티션만 조정
