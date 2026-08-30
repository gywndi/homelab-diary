# NAS 연동 (RWX 스토리지 + 백업 타깃)

[← 이전: 내부 도메인 DNS](09-internal-dns.md)

기존 NAS(`nas.home`, Synology)를 두 가지 용도로 클러스터에 붙였다. **① k8s의 ReadWriteMany(RWX) 스토리지**(여러 파드가 동시에 같은 파일을 쓰는 워크로드용) — [Ceph 스토리지](07-1-ceph-storage.md)의 설계 결정에서 "RWX가 필요해지면 NAS(NFS)로 커버한다"고 미뤄뒀던 것. **② etcd/MySQL 백업의 오프노드 사본** — 지금까지 백업이 만들어지는 그 노드(chan08)의 로컬 디스크에만 있었다는 단일 장애점을 없앤다.

## 목적

Ceph RBD는 한 클라이언트만 배타적으로 쓰는 블록 스토리지다. 여러 파드가 동시에 같은 디렉터리를 읽고 써야 하는 워크로드(RWX)는 처음부터 지원 대상이 아니었다([`07-1-ceph-storage.md`](07-1-ceph-storage.md) 참고 — CephFS는 MDS 운영 비용 때문에 배제했다). 이미 있는 NAS를 NFS로 노출해서 이 빈틈을 채운다. 같은 NAS 공유를 호스트에도 직접 마운트해서, chan08에 있던 백업들이 chan08 자체가 죽어도 살아남게 한다.

## 사전 조건

NAS 쪽 NFS 서비스와 공유 폴더는 이미 구성되어 있었다(DSM 제어판에서 NFS 활성화 + `/volume1/nas`를 `10.5.5.0/24`로 export). 이 문서는 k8s/호스트 쪽만 다룬다.

```bash
# NAS가 실제로 무엇을 얼마나 내주고 있는지 확인
showmount -e nas.home
#   /volume1/nas    10.5.5.0/24   <- 이 한 줄만 나온다: "볼륨 전체"가 아니라
#                                    "nas"라는 이름의 공유 폴더 하나만 노출된 것
```

## 설계 결정

- **iSCSI가 아니라 NFS다.** NAS는 iSCSI(SAN 블록 스토리지)도 지원하지만, iSCSI는 Ceph RBD와 같은 카테고리(네트워크로 붙는 블록 디바이스)라 근본적으로 ReadWriteOnce다 — 클라이언트 여러 개가 동시에 마운트하면 파일시스템 캐시가 서로 안 맞아 데이터가 깨진다. Oracle RAC처럼 여러 노드가 SAN(iSCSI/FC)을 진짜로 공유하는 사례도 있지만, 그건 iSCSI 자체가 아니라 그 위에 얹는 클러스터 인식 볼륨매니저(Oracle ASM)나 클러스터 파일시스템(OCFS2/GFS2)이 분산 락을 조율해주기 때문에 가능한 것이다. 이 클러스터를 위해 그 레이어를 새로 구축할 이유가 없다 — NFS는 서버(NAS) 쪽이 이미 여러 클라이언트의 동시 접근을 파일 단위로 중재해주므로, RWX가 애초에 이 프로토콜의 정상적인 사용법이다.
- **공유 폴더 안에 `k8s/` 하위 디렉터리로 범위를 한정한다.** `/volume1/nas`는 이미 다른 개인 데이터(예: `market/`)와 같이 쓰는 공유 폴더다. NFS는 DSM 로그인 같은 계정 인증이 없고 클라이언트 IP만 보고 열어주므로, k8s/백업 관련 데이터를 이 공유 폴더 전체에 흩뿌리지 않고 `k8s/` 밑으로만 모은다 — 이 폴더 자체를 따로(DSM에서 새 공유 폴더로) 분리하는 방법도 검토했지만, NFS가 이미 상위 디렉터리 단위로만 export되는 구조라 하위 디렉터리를 나누는 것만으로 충분히 목적(개인 데이터와 안 섞기)을 달성했다.
- **NFSv4가 아니라 NFSv3 + nolock.** `nfsvers=4`/`4.1`을 시도하면 이 NAS+드라이버 조합에서 `Protocol not supported`로 거부됐다. NFSv3로 낮추면 되는데, 이번엔 파일 잠금 데몬(`rpc.statd`)이 CSI 노드 컨테이너 안에 없어서 또 실패한다 — `nolock`(잠금 자체를 포기)으로 우회했다. 지금 워크로드가 여러 프로세스가 같은 파일을 동시에 잠그며 쓰는 게 아니라서 감수할 만한 절충이다.
- **StorageClass `reclaimPolicy: Retain`.** PVC를 지워도 NAS 위의 실제 데이터는 안 지워진다. RWX로 쓰는 데이터는 보통 여러 워크로드가 걸쳐있어서, PVC 하나 삭제했다고 데이터까지 자동으로 날아가면 위험하다 — 필요하면 `kubectl delete pv`로 수동으로 지운다.
- **백업은 로컬+NAS 이중화, NAS로 완전히 옮기지 않는다.** `/data/etcd-backup`(로컬)은 그대로 두고 NAS에 복사본을 추가로 남긴다. 로컬은 빠른 복구용, NAS는 "chan08 자체가 죽는" 시나리오에 대비한 사본 — 역할이 다르다.
- **NAS 백업 마운트는 k8s가 아니라 호스트 레벨.** etcd 스냅샷과 MySQL 덤프는 각각 etcd 파드의 hostPath와 chan08의 홈 디렉터리에서 만들어진다 — k8s PVC를 거칠 이유가 없다. 그냥 chan08에 NFS를 직접 마운트하는 쪽이 훨씬 단순하다.

## 디렉터리 구조

```
/volume1/nas/              (NAS 공유 폴더, 10.5.5.0/24에 NFS export)
├── market/                (기존 개인 데이터 — k8s와 무관, 안 건드림)
└── k8s/                   (k8s/백업 전용, 이 문서가 관리하는 전부)
    ├── backups/
    │   ├── etcd-backup/       (09-etcd-backup.sh가 자동으로 채움)
    │   └── mysql-backup/      (수동 백업 보관 — 아직 자동화된 주기 백업 없음)
    ├── rwx-pvs/                (k8s CSI가 PVC마다 자동 생성)
    └── docker-images/          (예약 — 추후 이미지 레지스트리/캐시 용도)
```

## 스크립트 목록 (이름 순)

### 호스트에 백업 타깃으로 마운트 + k8s용 디렉터리 준비
- 설명: chan08에 NAS를 마운트하고, 위 디렉터리 구조를 전부 만든다. 아래 CSI 설치보다 먼저 실행해야 한다(`rwx-pvs` 디렉터리가 미리 있어야 함).
- 스크립트: [`01-mount-nas-backup.sh`](../scripts/10-nas-storage/01-mount-nas-backup.sh)
```bash
sudo apt-get install -y nfs-common
sudo mkdir -p /mnt/nas-backup
sudo mount -t nfs -o vers=3,nolock nas.home:/volume1/nas /mnt/nas-backup

# 재부팅해도 유지되도록
echo "nas.home:/volume1/nas /mnt/nas-backup nfs vers=3,nolock,_netdev 0 0" | sudo tee -a /etc/fstab

# k8s 전용 하위 구조 (개인 데이터와 안 섞이게 전부 k8s/ 밑으로)
sudo mkdir -p /mnt/nas-backup/k8s/backups/etcd-backup \
              /mnt/nas-backup/k8s/backups/mysql-backup \
              /mnt/nas-backup/k8s/rwx-pvs \
              /mnt/nas-backup/k8s/docker-images
```

### k8s RWX 스토리지 (NFS CSI)
- 설명: `csi-driver-nfs`를 설치하고 `nfs-nas` StorageClass를 등록한다. `share`를 `k8s/rwx-pvs`로 한정해서, 이 StorageClass로 만드는 PV들이 `market/` 같은 다른 데이터와 안 섞이게 한다.
- 스크립트: [`02-deploy-nfs-csi.sh`](../scripts/10-nas-storage/02-deploy-nfs-csi.sh)
```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/v4.13.4/deploy/v4.13.4/rbac-csi-nfs.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/v4.13.4/deploy/v4.13.4/csi-nfs-driverinfo.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/v4.13.4/deploy/v4.13.4/csi-nfs-controller.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/v4.13.4/deploy/v4.13.4/csi-nfs-node.yaml
```
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-nas
provisioner: nfs.csi.k8s.io
parameters:
  server: nas.home
  share: /volume1/nas/k8s/rwx-pvs
reclaimPolicy: Retain
volumeBindingMode: Immediate
mountOptions:
  - nfsvers=3
  - nolock
```

### 기존 백업 스크립트에 NAS 사본 추가
- 설명: [`09-etcd-backup.sh`](../scripts/02-k8s-cluster/09-etcd-backup.sh)(chan08 등록 이름은 `07-etcd-backup.sh`)가 스냅샷을 뜬 뒤 `/mnt/nas-backup/k8s/backups/etcd-backup`에도 복사하도록 수정했다. NAS가 마운트 안 돼 있으면(여행 중 NAS 전원이 꺼져있다거나) 그 단계만 건너뛰고 로컬 백업은 그대로 진행한다 — 백업 자체가 NAS 의존성 때문에 실패하면 안 된다.
```bash
NAS_MOUNT="/mnt/nas-backup"
NAS_BACKUP_DIR="${NAS_MOUNT}/k8s/backups/etcd-backup"
# ...
if mountpoint -q "$NAS_MOUNT" 2>/dev/null; then
  mkdir -p "$NAS_BACKUP_DIR"
  cp "${BACKUP_DIR}/${SNAPSHOT_NAME}" "$NAS_BACKUP_DIR/"
  ls -1t "${NAS_BACKUP_DIR}"/etcd-snapshot-*.db | tail -n +"$((KEEP + 1))" | xargs -r rm -v --
else
  echo "경고: /mnt/nas-backup이 마운트돼 있지 않음 — NAS 복사 건너뜀" >&2
fi
```
MySQL 백업은 아직 주기적으로 자동화된 스크립트가 없다(지금까지의 덤프는 Ceph 마이그레이션 때 만든 1회성 백업). 기존 덤프는 `/mnt/nas-backup/k8s/backups/mysql-backup/`에 수동으로 옮겨뒀다 — 주기 백업이 필요해지면 이 문서의 etcd-backup과 같은 패턴(로컬 + NAS 사본)으로 새로 만들 것.

## 알려진 이슈

### NFS는 계정 인증이 없다 — 클라이언트 IP만 본다
DSM 웹 로그인이나 SMB와 달리, NFS export는 아이디/비밀번호 없이 **클라이언트가 허용된 IP 대역(`10.5.5.0/24`)에만 있으면** 바로 마운트되고 읽고 쓸 수 있다. `/volume1/nas` 공유 폴더에 이미 다른 개인 데이터가 같이 있었기 때문에, k8s/백업 관련 데이터를 전부 `k8s/` 하위로만 모아서 최소한 논리적으로는 분리해뒀다 — 근본적인 접근 제어(인증)가 필요해지면 DSM에서 이 공유 폴더 자체를 나누거나 export 허용 IP를 3노드로 좁히는 걸 검토할 것.

### NFSv4를 먼저 시도하면 이해하기 어려운 에러가 난다
`nfsvers=4`나 `4.1`로 StorageClass를 만들면 `mount.nfs: Protocol not supported`만 나오고 더 자세한 원인은 안 보인다. NFSv3로 낮추면 그제서야 진짜 원인(`rpc.statd is not running`)이 드러난다 — 이 NAS 환경에서는 그냥 처음부터 `nfsvers=3, nolock` 조합을 쓰는 게 시간을 아낀다.

### CSI 노드 파드 안에는 `rpc.statd`가 없다
NFSv3의 파일 잠금(`NLM`, Network Lock Manager)은 `rpc.statd`가 있어야 동작하는데, `csi-driver-nfs`의 노드 컨테이너는 이걸 안 띄운다. `nolock` 마운트 옵션으로 잠금 기능 자체를 포기하면 우회된다 — 여러 워크로드가 같은 파일을 동시에 잠그며 쓰는 게 아니라면 실무상 문제없다.

### StorageClass의 `parameters`는 불변이다
`share` 경로를 바꾸려고 기존 StorageClass에 `kubectl apply`만 다시 하면 `field is immutable` 에러가 난다 — `parameters` 아래 값은 생성 후 수정이 안 된다. 삭제하고 새로 만들어야 한다(이미 그 StorageClass로 만들어진 PV는 `reclaimPolicy: Retain`이라 영향받지 않는다).

## 검증 명령

```bash
# StorageClass 등록 확인
kubectl get storageclass nfs-nas

# RWX PVC로 실제 테스트 (다른 파드끼리 같은 파일 공유되는지)
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: nfs-test-pvc}
spec:
  accessModes: [ReadWriteMany]
  storageClassName: nfs-nas
  resources: {requests: {storage: 1Gi}}
EOF
kubectl get pvc nfs-test-pvc   # Bound이어야 함
kubectl delete pvc nfs-test-pvc
kubectl delete pv $(kubectl get pv -o jsonpath='{.items[?(@.spec.claimRef.name=="nfs-test-pvc")].metadata.name}')   # Retain이라 수동 정리 필요

# 호스트 백업 마운트 확인
ssh 10.5.5.8 "df -h /mnt/nas-backup"

# NAS에 실제로 백업이 쌓이는지
ssh 10.5.5.8 "ls -la /mnt/nas-backup/k8s/backups/etcd-backup /mnt/nas-backup/k8s/backups/mysql-backup"
```

---

[← 이전: 내부 도메인 DNS](09-internal-dns.md)
