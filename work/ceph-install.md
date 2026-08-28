# Ceph 설치

> 이 문서는 초안이다. 검증까지 끝나면 `lessons/`로 옮겨 다듬는다. 배경/설계 결정은 [소개](ceph-intro.md) 참고.

Rook-Ceph(v1.20.6) Operator로 배포했다 — Ceph 자체를 수동으로 설치하지 않고, k8s CRD(CephCluster/CephBlockPool/CephObjectStore)로 선언적으로 관리한다.

## 설치 순서

1. **방화벽 개방** (3노드 모두) — hostNetwork용 mon/osd/mgr/RGW 포트
2. **CSI 오퍼레이터 설치** — Rook 1.20부터 CSI 드라이버가 별도 오퍼레이터로 분리됨(`csi-operator.yaml`)
3. **Rook operator 설치** — CRD + operator 배포
4. **CephCluster 생성** — mon 3 + mgr 1 + OSD 3(노드별 디바이스 명시), hostNetwork
5. **CephBlockPool + StorageClass** — RBD 풀(3-replica) + exclusive-lock
6. **CephObjectStore** — RGW + MetalLB VIP 노출
7. **MySQL을 RBD PVC 기반 k8s 워크로드로 컷오버**
8. **디스크 재분할** — Ceph 고정 300G + 나머지 XFS(StarRocks BE용, 아래 상세 설명)

## 실행 중 발견한 이슈

- **Rook 1.20부터 CSI 드라이버가 별도 오퍼레이터로 분리됐다.** `crds.yaml` → `common.yaml` → `operator.yaml` 순서만 알고 있었는데, 실제로는 그 사이에 `csi-operator.yaml`(ceph-csi-operator의 `OperatorConfig`/`Driver` CRD)을 먼저 적용해야 한다. 빠뜨리면 "no matches for kind Driver/OperatorConfig" 에러가 난다.
- **operator reconcile이 에러 없이 멈추는 일이 반복됐다.** CephCluster CR을 두 번 apply했을 때(리소스 버전 충돌 이후 mon-a만 뜨고 멈춤), CephBlockPool 생성 때도(로그에 "successfully configured" 이벤트까지 찍히는데 실제 풀은 안 생기고 멈춤) 같은 패턴이 나왔다 — 에러 로그 없이 조용히 진행이 끊긴다. `kubectl rollout restart deployment/rook-ceph-operator`로 reconcile을 처음부터 다시 돌리면 정상 진행됐다. 진행이 몇 분 이상 안 보이면 우선 operator 재시작부터 시도할 것.
- **`kubectl wait`는 매칭되는 리소스가 하나도 없으면 즉시 에러를 낸다.** mon/osd 파드가 아직 생성되기 전에 `kubectl wait -l app=...`를 걸면 "no matching resources found"로 바로 실패한다 — 파드가 생기는 것부터 폴링한 뒤에 `wait`를 걸어야 한다.
- **RGW가 계속 멈춘 진짜 원인은 방화벽의 same-node hairpin 누락이었다.** 같은 노드(llm001) 안에서 pod network 파드(toolbox 등)가 hostNetwork Ceph 데몬에 접근할 때 소스 IP가 `10.5.5.0/24`가 아니라 pod CIDR(`10.244.0.0/16`)이라 방화벽 규칙에 안 걸려 TCP 연결 자체가 막혔다. `rados`/`radosgw-admin` 명령이 에러 메시지 없이 그냥 멈춰서(수 분씩 응답 대기) 처음엔 Rook 자체 버그로 오인했다 — `ceph tell osd.<N> version`으로 개별 데몬 응답성을 하나씩 확인하면서 특정 OSD 하나만 응답이 없는 걸로 좁혀야 찾을 수 있었다. 방화벽 스크립트에 pod CIDR 소스 예외 규칙을 추가해서 해결(3노드 모두 재적용 필요).
- **CephObjectStore의 gateway.service는 Service `type`을 지정할 수 없다.** annotations/labels만 지원해서, Rook이 소유한 `rook-ceph-rgw-*` Service를 `kubectl patch`로 LoadBalancer로 바꿔도 operator가 reconcile할 때마다 ClusterIP로 도로 바뀐다. Rook 소유 Service는 그대로 두고, 같은 파드 라벨을 셀렉터로 쓰는 별도 Service를 만들어 그것만 LoadBalancer로 노출하는 방식으로 해결.
- **CephObjectStore 삭제가 자기 자신을 참조하는 순환으로 멈췄다.** 방화벽 문제로 실패했던 시도들이 `.rgw.root`에 realm/zonegroup/zone은 만들어졌지만 period가 없는 반쪽 상태를 남겼는데, 이 CR을 지우려 하면 finalizer가 "버킷이 있는지" 확인하려고 RGW 자신의 HTTP API를 호출한다 — 근데 그 RGW는 애초에 뜬 적이 없으니 연결 거부로 finalizer가 영원히 못 끝난다. 버킷이 존재한 적이 없다는 걸 확인한 뒤 finalizer를 강제로 비우고, 남은 rados 오브젝트/풀은 직접 정리한 뒤 처음부터 재생성했다.
- **datadir을 옮겨도 binlog는 안 따라온다(MySQL 이전 때).** `datadir`을 바꿨는데 별도 튜닝 설정 파일에 `log_bin`이 절대경로로 하드코딩되어 있어서 안 따라오고 계속 옛 경로에 쓰고 있었다 — datadir 설정과 별개인 절대경로 항목(log_bin, innodb_undo_directory 등)을 따로 확인해야 한다.
- **AppArmor 로컬 오버라이드도 같이 옮겨야 한다.** Ubuntu MySQL 패키지는 `/etc/apparmor.d/local/usr.sbin.mysqld`에 datadir 경로를 화이트리스트로 걸어둔다. 새 경로를 추가하지 않으면 mysqld가 파일 접근을 거부당하며 죽는다.
- **되돌릴 수 없는 원격 명령은 Claude Code 자동 모드 분류기가 막는다.** `wipefs` 같은 명령은 세션 권한으로 승인해도 별도 분류기가 한 번 더 막아서, 프로젝트 로컬 설정(`.claude/settings.local.json`)에 해당 호스트로의 ssh/scp를 허용 규칙으로 추가해야 진행할 수 있었다.

## 디스크 재분할: Ceph 고정 300G + XFS (명령어 설명)

StarRocks shared-nothing(BE) 테스트를 위한 로컬 스토리지를 확보하려고, 각 노드 디스크를 "Ceph OSD 고정 300G + 나머지 XFS"로 재분할했다. 재사용 가능한 스크립트: [`12-resplit-osd-disk.sh`](../scripts/07-ceph-storage/12-resplit-osd-disk.sh)(chan08/chan09처럼 Ceph 전용 디스크가 따로 있는 경우).

### 사전 단계 (한 노드씩, 순차)

디스크를 직접 건드리기 전에, 그 노드의 OSD를 Ceph에서 안전하게 빼야 한다:

```bash
ceph osd out osd.<N>              # 이 OSD를 "제외" 표시 — 데이터가 다른 OSD로 재분산(remap)되기 시작
# ceph -s로 misplaced(무해)만 있고 degraded/peering이 없을 때까지 대기 → active+clean 확인
kubectl -n rook-ceph delete deployment rook-ceph-osd-<N>   # OSD 데몬 파드 제거
ceph osd purge osd.<N> --yes-i-really-mean-it              # Ceph 카탈로그에서 완전히 제거
```

`ceph osd purge`가 `Error EBUSY: osd.N is not down`을 낼 때가 있었는데, 데몬이 완전히 등록 해제될 때까지 몇 초 기다렸다 재시도하면 해결됐다.

### 재분할 스크립트 명령어 하나씩 설명

```bash
sudo fuser -vm "$DEVICE"
```
디바이스를 사용 중인 프로세스가 있는지 확인. 있으면(마운트가 안 풀렸거나 다른 프로세스가 열고 있으면) 재파티션이 실패하거나 위험하므로 먼저 확인.

```bash
sudo wipefs -a "${DEVICE}1"
sudo wipefs -a "$DEVICE"
```
기존 파일시스템/파티션 시그니처(magic byte)를 지운다. 파티션 1이 있으면 먼저 지우고(디바이스 자체를 지우기 전에 하위 파티션부터), 그다음 디바이스 전체의 파티션 테이블 시그니처를 지운다 — 이렇게 안 하면 이후 `parted`가 "이미 파티션이 있다"고 헷갈리거나 커널이 옛 파티션을 계속 인식하는 경우가 있다.

```bash
sudo parted -s "$DEVICE" mklabel msdos
sudo parted -s "$DEVICE" mkpart primary 1MiB "$CEPH_SIZE"
sudo parted -s "$DEVICE" mkpart primary "$CEPH_SIZE" 100%
sudo partprobe "$DEVICE"
```
`-s`(script 모드, 확인 프롬프트 없이 실행)로 MSDOS(MBR) 파티션 테이블을 새로 만들고, 파티션 1(1MiB~`CEPH_SIZE`, 예: 300GB — Ceph OSD용)과 파티션 2(`CEPH_SIZE`~100%, 나머지 전부 — XFS용)를 순서대로 만든다. 시작을 1MiB부터 하는 건 정렬(4K 섹터 정렬 등) 문제를 피하기 위한 관례. `partprobe`는 커널에 파티션 테이블이 바뀌었다고 알려서 `/dev/sda1`, `/dev/sda2` 디바이스 노드를 새로 인식시킨다.

```bash
sudo dd if=/dev/zero of="$CEPH_PART" bs=1M count=112640
```
**가장 중요한 단계.** 새로 만든 Ceph 파티션의 앞 110GiB(112640MB)를 전부 0으로 덮어쓴다. BlueStore는 OSD 레이블을 원본 디스크 크기 기준으로 **1GB, 10GB, 107GB 지점에 중복 저장**해두는데, 파티션을 줄인 뒤 앞부분 일부(우리가 처음 시도했던 200MB)만 지우면 이 레이블들이 그대로 남아 Rook이 "새 OSD 생성"이 아니라 "기존 OSD 확장(expand-bluefs)"으로 오판해 계속 크래시한다. `ceph-bluestore-tool show-label --dev <device>`로 실제 레이블 위치(`locations: [...]`)를 직접 확인할 수 있다. 110GB는 이 세 지점을 전부 덮기 위한 여유값.

```bash
sudo mkfs.xfs -f "$XFS_PART"
sudo mkdir -p "$MOUNT_PATH"
sudo mount "$XFS_PART" "$MOUNT_PATH"
UUID=$(sudo blkid -s UUID -o value "$XFS_PART")
echo "UUID=${UUID} ${MOUNT_PATH} xfs defaults 0 2" | sudo tee -a /etc/fstab
```
두 번째 파티션을 XFS로 포맷(`-f`는 기존 파일시스템이 있어도 강제로 덮어씀)하고, 마운트 포인트를 만든 뒤 마운트한다. UUID를 뽑아서 `/etc/fstab`에 추가 — 디바이스 이름(`/dev/sda2`)이 아니라 UUID로 등록해야 재부팅 시 디바이스 순서가 바뀌어도 안전하게 같은 파티션을 찾는다.

### 재프로비저닝 (스크립트 실행 후)

```bash
kubectl -n rook-ceph delete job rook-ceph-osd-prepare-<node>   # 있으면 삭제 — 없으면 Rook이 "디바이스 이름 안 바뀜"으로 착각해 재실행을 건너뜀
kubectl -n rook-ceph rollout restart deployment/rook-ceph-operator
# ceph -s로 새 OSD가 생기고 전체 PG가 active+clean이 될 때까지 대기
```

### llm001은 스크립트 대신 수동으로

llm001은 OS(EFI+root)와 Ceph OSD가 같은 물리 디스크(GPT)를 공유하고 있어서, 위 스크립트(MSDOS 파티션 테이블을 새로 씀)를 그대로 쓰면 OS 파티션까지 날아간다. 대신 OSD가 쓰던 파티션(디스크의 마지막 파티션이라 안전하게 가능했다)만 `parted rm <번호>`로 지우고, **같은 시작 오프셋**으로 더 작은 크기(300G)와 나머지(XFS)로 재생성했다 — EFI/root 파티션은 전혀 건드리지 않았다. BlueStore 110GB 제로화는 동일하게 적용.

### 결과

| 노드 | Ceph OSD | XFS(BE용) |
|---|---|---|
| chan08 | osd.3, `/dev/sda1` 279G | `/dev/sda2` 652G → `/mnt/starrocks-be` |
| chan09 | osd.0, `/dev/sda1` 279G | `/dev/sda2` 652G → `/mnt/starrocks-be` |
| llm001 | osd.1, `/dev/nvme0n1p3` 280G | `/dev/nvme0n1p4` 451G → `/mnt/starrocks-be` |

재분할 후 raw 용량은 2.5TiB → 838GiB로 줄었지만(의도한 트레이드오프), 3노드를 동일 크기(300G)로 맞추면서 OSD별 사용률/PG 분산이 거의 완벽하게 균등해졌다(`ceph osd df` 기준 VAR 1.00/1.00, STDDEV 0.01) — 이전엔 노드마다 디스크 크기가 달라서(932G/932G/730G) 약간의 불균형이 있었는데 오히려 개선됐다.

부수적으로 두 가지 더 배웠다:
- Rook의 osd-prepare Job은 디바이스 구성이 안 바뀐 것처럼 보이면(디바이스 이름이 같으면) 재실행을 스킵한다 — 강제로 다시 돌리려면 완료된 Job을 직접 삭제해야 한다.
- 이전에 실패했거나 삭제한 OSD의 Deployment가 operator 재시작 때마다 유령처럼 되살아나는 경우가 있었다(`CrashLoopBackOff`/`Init:Error` 상태로) — 매번 `kubectl delete deployment`로 정리해야 했다.

전체 재분할은 노드 하나씩 순차로(안전 우선) 진행했고, MySQL 전체 백업을 새로 뜬 뒤 시작했다. 3노드 모두 size=3(RBD)/size=2(RGW) 풀이 매 순간 min_size 이상을 유지한 채 진행해서 데이터 손실 없이 완료했다.

## 스크립트 목록

- 방화벽: [`00-open-ceph-firewall-ports.sh`](../scripts/07-ceph-storage/00-open-ceph-firewall-ports.sh) — 3노드 모두에서 실행
- operator: [`01-install-rook-operator.sh`](../scripts/07-ceph-storage/01-install-rook-operator.sh) — Rook CRD/operator 설치 (v1.20.6)
- 클러스터: [`02-apply-cluster.sh`](../scripts/07-ceph-storage/02-apply-cluster.sh) + [`02-cluster.yaml`](../scripts/07-ceph-storage/02-cluster.yaml)
- 블록 스토리지: [`03-apply-storageclass.sh`](../scripts/07-ceph-storage/03-apply-storageclass.sh) + [`03-storageclass.yaml`](../scripts/07-ceph-storage/03-storageclass.yaml)
- 오브젝트 스토리지: [`04-apply-objectstore.sh`](../scripts/07-ceph-storage/04-apply-objectstore.sh) + [`04-objectstore.yaml`](../scripts/07-ceph-storage/04-objectstore.yaml)
- MySQL 백업: [`05-backup-mysql.sh`](../scripts/07-ceph-storage/05-backup-mysql.sh)
- MySQL 이전(임시): [`06-relocate-mysql-datadir.sh`](../scripts/07-ceph-storage/06-relocate-mysql-datadir.sh)
- 디스크 wipe: [`07-wipe-data-disk.sh`](../scripts/07-ceph-storage/07-wipe-data-disk.sh)
- MySQL k8s 리소스: [`08-mysql-configmap-pvc.yaml`](../scripts/07-ceph-storage/08-mysql-configmap-pvc.yaml)
- MySQL 데이터 이전: [`09-mysql-migrate-data.sh`](../scripts/07-ceph-storage/09-mysql-migrate-data.sh)
- MySQL 배포: [`10-mysql-deploy.yaml`](../scripts/07-ceph-storage/10-mysql-deploy.yaml)
- MySQL VIP 컷오버: [`11-mysql-vip-cutover.sh`](../scripts/07-ceph-storage/11-mysql-vip-cutover.sh)
- 디스크 재분할: [`12-resplit-osd-disk.sh`](../scripts/07-ceph-storage/12-resplit-osd-disk.sh) — 전용 데이터 디스크(chan08/chan09 sda 패턴)용. llm001처럼 OS와 디스크를 공유하는 경우는 수동으로 대상 파티션만 조정
- [`app-sample.py`](../scripts/07-ceph-storage/app-sample.py) — 실제 동작하는 클라이언트 샘플, 상세는 [어플리케이션 샘플](ceph-app-sample.md)
