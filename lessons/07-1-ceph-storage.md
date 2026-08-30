# Ceph 스토리지 (RBD/RGW)

3노드(chan08/chan09/llm001) 전체를 재구성해서 만든 공용 스토리지 계층이다. Ceph는 여러 서버의 디스크를 묶어서 네트워크로 복제되는 하나의 스토리지 풀로 만들어주는 분산 스토리지 시스템이다. 배포·운영은 cephadm이 맡는다. cephadm은 Ceph 공식 배포 도구로, 각 노드에 컨테이너(podman)+systemd 유닛으로 데몬을 직접 띄운다 — k8s API/스케줄러와 무관하게 동작한다. RBD(블록)는 MySQL/KVM이 쓴다. RGW(오브젝트, S3 API)는 오브젝트 API가 필요한 다른 워크로드가 쓴다. 새 장비 없이 기존 노드를 재구성하는 것만으로 진행했다.

## 목적

그동안 MySQL 데이터와 KVM VM 디스크는 각 노드 로컬 디스크에 흩어져 있었다. 이걸 네트워크로 복제되는 공용 스토리지 계층으로 옮겼다. 목표는 "노드 장애 = 데이터 손실"이 되지 않게 분리하는 것이었다. 동시에 S3 호환 오브젝트 API(RGW)도 마련했다. 로컬 디스크가 아니라 오브젝트 스토리지가 필요한 워크로드도 같은 클러스터로 받을 수 있게 됐다.

Ceph 자체는 k8s 워크로드가 아니라 다른 서비스가 의존하는 핵심 인프라다. k8s를 밀고 다시 세우는 작업이 스토리지까지 같이 죽여선 안 된다. 그래서 k8s 안이 아니라 베어메탈에 직접 cephadm으로 배포한다 — CoreDNS, k8s API 서버 VIP와 같은 층에 있는 인프라로 취급한다.

## 대상 노드

| 노드 | IP | OSD 파티션 | 크기 |
|---|---|---|---|
| chan08 | 10.5.5.8 | `/dev/sda1` | 500G |
| chan09 | 10.5.5.9 | `/dev/sda1` | 500G |
| llm001 | 10.5.5.10 | `/dev/nvme0n1p3` | 500G |

각 파티션은 LVM 논리 볼륨(`ceph-osd-vg/osd-data`)으로 한 겹 감싸서 OSD로 등록한다 — 이유는 아래 "설계 결정" 참고. 나머지 디스크 공간은 XFS로 별도 마운트(`/mnt/starrocks-be`, StarRocks shared-nothing 로컬 테스트용) — 파티션을 어떻게 나눴는지는 아래 "디스크 재분할" 참고.

## 설계 결정

- **새 장비 없이 기존 3노드 재구성.** Ceph는 기본값으로 데이터를 3벌 복제한다(3-replica). 마침 물리 노드가 정확히 3대라 딱 맞는다.
- **RBD(블록)와 RGW(오브젝트)의 역할을 분리했다.** 블록 스토리지는 일반 디스크처럼 운영체제에 통째로 마운트해 파일시스템을 얹는 방식이다. 오브젝트 스토리지는 파일 하나하나를 HTTP API(S3)로 읽고 쓰는 방식이다. 접근 패턴이 다르다 — KVM VM 디스크와 MySQL 데이터는 항상 한 프로세스만 배타적으로 쓰는 블록 데이터라 RBD를 쓴다. 오브젝트 API로 접근하는 워크로드는 RGW를 쓴다.
- **CephFS(MDS)는 배제했다.** CephFS는 Ceph 위에 파일시스템을 얹어주는 세 번째 방식이다. 여러 클라이언트가 동시에 같은 디렉터리를 공유할 수 있다. MDS(메타데이터 서버)라는 별도 데몬이 필요하다. 지금은 여러 파드가 동시에 같은 파일을 읽고 써야 하는 워크로드(k8s에서는 RWX, ReadWriteMany라 부름)가 없다. MDS를 상시 구동할 비용을 32G/노드 예산에서 정당화할 근거가 없었다. RWX가 필요해지면 NAS(NFS)로 커버할 계획이다.
- **NAS를 OSD 백엔드로 쓰지 않는다.** OSD는 디스크 하나당 데이터를 저장하는 Ceph 데몬이다(아래 "각 컴포넌트가 뭘 하는지" 참고). 네트워크 스토리지 위에 또 네트워크 스토리지를 얹으면 지연/장애 시나리오가 한 겹 더 지저분해진다. NAS는 백업 타깃과 향후 NFS StorageClass 용도로만 쓰기로 좁혔다.
- **KVM도 RBD 위에 올린다.** libvirt(KVM을 관리하는 가상화 툴킷)가 RBD를 네이티브 스토리지 풀로 지원한다. 다만 libvirt 도메인 XML(VM 정의 파일)을 노드 간 자동 동기화해주는 장치는 없다. 수동 절차로 남아있다.
- **cephadm으로 베어메탈에 직접 배포한다.** k8s CRD로 선언적으로 관리하는 방식(Rook 같은 오퍼레이터)도 있지만, 그러면 Ceph의 생사가 k8s 컨트롤플레인에 묶인다. cephadm은 각 노드에 SSH로 접속해 컨테이너+systemd로 데몬을 직접 배포·관리한다. k8s가 죽어도, 심지어 k8s를 통째로 밀고 다시 세워도 Ceph는 영향받지 않는다.
- **OSD 파티션은 LVM 논리 볼륨으로 감싸서 등록한다.** cephadm의 표준 OSD 생성 경로(`ceph orch daemon add osd`)는 raw 파티션을 직접 못 받는다 — LVM(pvcreate/vgcreate/lvcreate)으로 한 겹 감싸야 받아준다.
- **RGW VIP는 keepalived로, 인프라 대역에 둔다.** RGW가 k8s Service가 아니라서 MetalLB(k8s LoadBalancer용)를 못 쓴다. MySQL Stage 1/k8s API 서버 VIP와 같은 host-native VRRP 패턴(keepalived)을 재사용한다. VIP는 인프라 대역(`.20` 이하) — Ceph는 다른 서비스가 의존하는 핵심 인프라라 애플리케이션 VIP 대역(`.50~.99`)과 구분한다.
- **k8s에서 RBD를 쓰려면 독립 ceph-csi를 붙인다.** MySQL 같은 k8s 워크로드는 여전히 PVC로 스토리지를 쓰고 싶어한다. Rook 대신 ceph-csi(RBD 플러그인)만 독립적으로 배포한다. k8s는 이 외부 클러스터의 "소비자" 역할만 하고, 클러스터 자체의 생애주기는 전혀 관리하지 않는다.

MySQL이 이 RBD 위에서 실제로 어떻게 재배포됐는지는 [MySQL을 Ceph RBD로 재배포](03-2-mysql-ceph-migration.md) 참고.

## 아키텍처

3개 층으로 나눠서 보면 이해하기 쉽다. **① 물리 노드**는 디스크를 실제로 들고 있다. **② Ceph 저장 계층**은 그 디스크들을 묶어서 블록/오브젝트로 재포장한다. **③ 소비자**는 그 저장소를 실제로 쓰는 워크로드다.

```mermaid
flowchart LR
    subgraph NODES["① 물리 노드 3대"]
        direction TB
        N08["chan08<br/>디스크 중 500G를 OSD로"]
        N09["chan09<br/>디스크 중 500G를 OSD로"]
        N10["llm001<br/>디스크 중 500G를 OSD로"]
    end

    NODES == "데이터를 3벌씩 복제<br/>(3-replica)" ==> POOL

    subgraph POOL["② Ceph 저장 계층(cephadm, 베어메탈)"]
        direction TB
        RBD["RBD<br/>(블록 — 한 클라이언트만 배타 접근)"]
        RGW["RGW<br/>(오브젝트 — S3 API로 다중 접근)"]
    end

    subgraph CONSUMERS["③ 소비자"]
        direction TB
        KVM["KVM VM 디스크"]
        MYSQL["MySQL(k8s, ceph-csi 경유)<br/>(RWO PVC, 단일 인스턴스)"]
        EXT["오브젝트 API가<br/>필요한 다른 워크로드"]
    end

    RBD --> KVM
    RBD --> MYSQL
    RGW --> EXT
```

각 노드는 디스크 전체를 Ceph에 주지 않는다. 500G만 OSD로 떼어주고, 나머지는 별도 파일시스템(XFS)으로 남겨 다른 용도로 쓴다. 이 문서는 Ceph만 다루므로 그 용도는 다루지 않는다. 디스크를 어떻게 나눴는지 절차는 아래 "디스크 재분할" 참고.

| 컴포넌트 | 역할 |
|---|---|
| mon | 클러스터 맵(OSD 생사, 데이터 위치) 합의 관리. 과반수 필요 — 3개(홀수) 배포 |
| mgr | 대시보드, 메트릭, 관리 API |
| OSD | 디스크 하나당 하나, BlueStore 포맷으로 직접 디스크 관리(파일시스템 안 거침) |
| RBD | OSD 위 블록 디바이스 계층 — 단일 클라이언트 배타 사용(exclusive-lock) |
| RGW | OSD 위 S3/Swift 호환 오브젝트 API 계층 — 다중 클라이언트 동시 접근 |

## 스크립트 목록 (이름 순)

### 클러스터 부트스트랩(mon+mgr)
- 설명: cephadm 설치 후 클러스터를 만든다. 부트스트랩 직후 레거시 cephx 키(krbd 호환)를 허용하도록 설정한다 — 이유는 아래 "알려진 이슈" 참고. chan08(관리 노드) 1회만 실행한다.
- 스크립트: [`14-cephadm-bootstrap.sh`](../scripts/07-ceph-storage/14-cephadm-bootstrap.sh)
```bash
# cephadm 설치 스크립트 다운로드(Squid 릴리스)
curl --silent --remote-name --location https://download.ceph.com/rpm-squid/el9/noarch/cephadm
chmod +x cephadm

# 호스트 사전 점검
./cephadm check-host

# 클러스터 부트스트랩(mon+mgr)
./cephadm bootstrap \
  --mon-ip 10.5.5.8 \
  --cluster-network 10.5.5.0/24 \
  --allow-fqdn-hostname \
  --initial-dashboard-user admin \
  --initial-dashboard-password <생성 시 랜덤 문자열, 실행할 때마다 새로 만들어짐> \
  --dashboard-password-noupdate

# cephadm을 시스템 PATH에 설치
cp ./cephadm /usr/local/bin/cephadm
chmod +x /usr/local/bin/cephadm

# 레거시 cephx 키(krbd 호환) 허용
cephadm shell -- ceph mon set auth_allowed_ciphers "aes, aes256k"
cephadm shell -- ceph mon set auth_preferred_cipher aes
```

### 컨테이너 런타임 설치
- 설명: cephadm이 Ceph 데몬을 담을 컨테이너 런타임(podman)을 3노드 전부에 설치한다.
- 스크립트: [`13-install-podman.sh`](../scripts/07-ceph-storage/13-install-podman.sh)
```bash
sudo apt-get update -y
sudo apt-get install -y podman
```

### 클러스터에 호스트 추가
- 설명: 나머지 노드를 클러스터에 추가한다. cephadm이 root로 SSH 접속해 데몬을 배포하므로 클러스터 SSH 공개키를 대상 호스트의 root에 먼저 넣는다. chan09, llm001 각각 실행한다.
- 스크립트: [`15-cephadm-add-host.sh`](../scripts/07-ceph-storage/15-cephadm-add-host.sh)
```bash
# 클러스터 SSH 공개키를 대상 호스트 root에 등록
PUBKEY=$(cat /etc/ceph/ceph.pub)
ssh chan@10.5.5.9 "sudo mkdir -p /root/.ssh && echo '${PUBKEY}' | sudo tee -a /root/.ssh/authorized_keys > /dev/null && sudo chmod 700 /root/.ssh && sudo chmod 600 /root/.ssh/authorized_keys"

# 클러스터에 호스트 추가
cephadm shell -- ceph orch host add chan09 10.5.5.9
```

### OSD 등록
- 설명: 노드의 Ceph 전용 파티션을 LVM 논리 볼륨으로 감싼 뒤 OSD로 등록한다. 3노드 각각 실행한다.
- 스크립트: [`16-cephadm-add-osd.sh`](../scripts/07-ceph-storage/16-cephadm-add-osd.sh)
```bash
# 파티션을 LVM 논리 볼륨으로 감싸기(대상 노드에서)
sudo pvcreate /dev/sda1
sudo vgcreate ceph-osd-vg /dev/sda1
sudo lvcreate -l 100%FREE -n osd-data ceph-osd-vg

# OSD로 등록(chan08에서)
cephadm shell -- ceph orch daemon add osd "chan08:/dev/ceph-osd-vg/osd-data"
```

### RBD(블록) 풀 생성
- 설명: MySQL/KVM이 쓸 RBD 풀을 만든다(3-replica).
- 스크립트: [`17-cephadm-rbd-pool.sh`](../scripts/07-ceph-storage/17-cephadm-rbd-pool.sh)
```bash
# 32 PG로 풀 생성
cephadm shell -- ceph osd pool create rbd-pool 32 32 replicated

# 3-replica 설정
cephadm shell -- ceph osd pool set rbd-pool size 3
cephadm shell -- ceph osd pool set rbd-pool min_size 2

# RBD 용도로 초기화
cephadm shell -- rbd pool init rbd-pool
cephadm shell -- ceph osd pool application enable rbd-pool rbd
```

### RGW(오브젝트) 데몬 배치
- 설명: RGW 데몬을 3노드 전부에 배치한다. RGW는 상태 없는(stateless) 데몬이라 더 넓게 분산할수록 유리하다.
- 스크립트: [`18-cephadm-rgw.sh`](../scripts/07-ceph-storage/18-cephadm-rgw.sh)
```bash
cephadm shell -- ceph orch apply rgw starrocks-store --placement="chan08,chan09,llm001" --port=7480
```

### RGW VIP(keepalived)
- 설명: RGW 앞단에 keepalived VIP(`10.5.5.4`, `ceph.home`)를 구성한다. 3노드 각각 실행한다 — 상태/우선순위만 다르게 준다.
- 스크립트: [`19-cephadm-rgw-keepalived.sh`](../scripts/07-ceph-storage/19-cephadm-rgw-keepalived.sh)
```bash
# RGW 헬스체크 스크립트
cat > /usr/local/bin/chk_rgw.sh <<'EOF'
#!/bin/bash
curl -sf -o /dev/null http://127.0.0.1:7480/
EOF
chmod +x /usr/local/bin/chk_rgw.sh

# vrrp_instance VI_RGW 블록을 keepalived.conf에 추가(virtual_router_id=53 — 51=MySQL 폐기, 52=k8s API와 안 겹치게)
# chan08: state MASTER priority 150 / chan09: BACKUP 140 / llm001: BACKUP 130, 공통 virtual_ipaddress 10.5.5.4/24

sudo systemctl enable --now keepalived
sudo systemctl restart keepalived
```

### k8s 쪽 ceph-csi 배포
- 설명: k8s가 RBD를 PVC로 쓸 수 있게 독립 ceph-csi(Rook 아님)를 배포한다. 전용 cephx 유저(`client.k8s`, least-privilege)로 인증한다.
- 스크립트: [`20-deploy-ceph-csi.sh`](../scripts/07-ceph-storage/20-deploy-ceph-csi.sh)
```bash
# 전용 cephx 유저 생성
cephadm shell -- ceph auth get-or-create client.k8s \
  mon 'profile rbd' \
  osd 'profile rbd pool=rbd-pool' \
  mgr 'profile rbd pool=rbd-pool'

# ceph-csi 공식 매니페스트(v3.17.1) 다운로드 + namespace를 ceph-csi로 치환
curl -s -o csi-rbdplugin.yaml https://raw.githubusercontent.com/ceph/ceph-csi/v3.17.1/deploy/rbd/kubernetes/csi-rbdplugin.yaml
sed -i "s/namespace: default/namespace: ceph-csi/g" csi-rbdplugin.yaml

# StorageClass(krbd 기본 마운터, mounter 파라미터 지정 안 함)
kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-csi-rbd
provisioner: rbd.csi.ceph.com
parameters:
  pool: rbd-pool
  imageFeatures: layering
reclaimPolicy: Delete
allowVolumeExpansion: true
EOF
```

### 디스크 재분할 — Ceph 고정 500G + XFS
- 설명: 디스크 전체를 OSD에 주지 않는다. 다른 용도로 쓸 로컬 스토리지를 같은 디스크에서 떼어 남겨두려고, OSD 전용 디스크를 "Ceph 고정 500G + 나머지 XFS"로 재분할한다. llm001은 OS와 디스크(GPT)를 공유해서 이 스크립트 대신 대상 파티션만 `parted rm`으로 지우고 같은 시작 오프셋에서 수동으로 재생성했다.
- 스크립트: [`12-resplit-osd-disk.sh`](../scripts/07-ceph-storage/12-resplit-osd-disk.sh) — 디바이스/Ceph 파티션 크기/마운트 경로를 인자로 받는다. chan08/chan09 둘 다 아래 값 그대로 실행했다: `sudo ./12-resplit-osd-disk.sh /dev/sda 500GB /mnt/starrocks-be`
```bash
# 기존 시그니처 정리(파티션 + 디스크 전체)
sudo wipefs -a /dev/sda1
sudo wipefs -a /dev/sda

# p1=Ceph용 500GB
sudo parted -s /dev/sda mklabel msdos
sudo parted -s /dev/sda mkpart primary 1MiB 500GB

# p2=나머지(XFS)
sudo parted -s /dev/sda mkpart primary 500GB 100%
sudo partprobe /dev/sda

# 나머지 파티션을 XFS로 포맷
sudo mkfs.xfs -f /dev/sda2

# 마운트 경로 생성 + 마운트
sudo mkdir -p /mnt/starrocks-be
sudo mount /dev/sda2 /mnt/starrocks-be

# 재부팅해도 안 바뀌는 UUID 확인
sudo blkid -s UUID -o value /dev/sda2

# 디바이스 이름이 아니라 UUID로 fstab에 등록 — 재부팅 시 디바이스 순서가 바뀌어도 안전
# (예: UUID=2e346eca-8a4d-4d59-8897-4b5d84aefdc3  /mnt/starrocks-be  xfs  defaults  0  2)
```
결과: 3노드 전부 OSD 500G로 균등화됐다. 나머지는 `/mnt/starrocks-be`에 마운트(chan08/09 457G, llm001 260G — OS와 디스크를 공유해서 더 작음).

### 애플리케이션에서 RGW 쓰기(boto3 S3 API)
- 설명: RGW는 애플리케이션이 보통 S3 API로 직접 접근한다. RBD는 k8s CSI/libvirt가 대신 처리해서 애플리케이션 코드가 직접 다루지 않는다. 버킷 생성은 `radosgw-admin`으로는 안 된다. S3 API로만 가능하다. 유저를 먼저 만든 뒤 boto3로 접근한다.
- 스크립트: [`app-sample.py`](../scripts/07-ceph-storage/app-sample.py)
```bash
# 전용 유저 생성(버킷 생성은 이 명령으로 안 됨 — 아래 S3 API로)
cephadm shell -- radosgw-admin user create --uid=demo-app --display-name="Demo App"
```
```python
s3 = boto3.client("s3", endpoint_url="http://10.5.5.4:7480",
                   aws_access_key_id=ACCESS_KEY, aws_secret_access_key=SECRET_KEY,
                   region_name="default")   # boto3가 SigV4에 region을 요구 — RGW는 안 봐도 빈 값은 안 됨

s3.create_bucket(Bucket="demo-app-bucket")
s3.put_object(Bucket="demo-app-bucket", Key="reports/2026-08-30.json", Body=b'{"status": "ok"}')
```
RGW VIP(`ceph.home`, `10.5.5.4`)는 keepalived로 노출된다. 클러스터 안팎 어디서든 접근 가능하다(k8s 내부 전용 아님). 버킷 생성은 몇 번을 반복해도 결과가 같은 동작(idempotent)이 아니다. 이미 있는 버킷에 재호출하면 `BucketAlreadyExists`(소유자 다름) 또는 `BucketAlreadyOwnedByYou`(같음) 에러가 난다.

## 알려진 이슈

### 신규 클러스터의 기본 인증키가 커널 krbd와 안 맞았다
krbd(커널 RBD) 매핑이 `secret too big` 에러로 실패하는 문제가 있었다. Ceph 클러스터가 처음 생성될 때 잡는 기본 인증 방식이 원인이었다 — `ceph mon set auth_allowed_ciphers "aes, aes256k"`로 호환 모드를 열어 해결했다(부트스트랩 스크립트에 포함됨).

### `ceph orch daemon add osd`는 raw 파티션을 못 받는다
LVM 논리 볼륨으로 한 겹 감싼 뒤(`pvcreate`/`vgcreate`/`lvcreate`) 그 LV 경로를 넘기면 된다.

### 우분투 24.04(noble)엔 Ceph 공식 apt 저장소가 없다
호스트에 `ceph`/`rbd` CLI를 직접 깔면 버전이 안 맞아 keyring 파싱 에러가 난다. `cephadm shell -- ceph ...`(데몬과 항상 버전이 일치하는 컨테이너 안에서 실행)를 표준 경로로 쓴다.

### ceph-csi는 공식 매니페스트에 없는 `ceph-config` ConfigMap을 요구한다
빈 내용으로라도 직접 만들어줘야 `csi-rbdplugin` 파드가 뜬다.

### 디스크를 재분할하면 그 위 hostPath 디렉터리도 같이 사라진다
StarRocks shared-nothing BE가 쓰는 `/mnt/starrocks-be/sn-data`는 XFS 파티션 위 디렉터리라서, 파티션을 다시 나누면 같이 없어진다. BE를 다시 배포하기 전에 노드마다 새로 만들어야 한다.

## 검증 명령

```bash
# chan08에서 실행
cephadm shell -- ceph -s        # 전체 상태(HEALTH_OK/WARN)
cephadm shell -- ceph osd tree  # OSD별 노드 배치/생존 확인
cephadm shell -- ceph osd df    # OSD별 사용률/PG(데이터를 나눠 OSD에 분산 배치하는 단위) 분산 균형도
cephadm shell -- ceph orch ps   # 데몬(mon/mgr/osd/rgw) 배치 현황
```

## 검증 이력

2026-08-30 전체 스택 검증 완료:
1. `ceph -s` HEALTH_OK, mon/mgr/osd 3개씩 정상, `rbd-pool`(size=3/min_size=2) 생성 확인
2. RGW 3노드 배치 확인, VIP(`10.5.5.4`, `ceph.home`)로 curl 200 응답 확인
3. krbd 매핑 실제 테스트(`/dev/rbd0` 생성) + k8s 파드에서 ceph-csi PVC 마운트·쓰기·읽기 확인
4. MySQL을 새 `ceph-csi-rbd` StorageClass로 재배포, 원본 백업(mysqldump) 전체 복원 후 정확한 행 수로 데이터 무결성 확인
5. StarRocks shared-data(FE+CN, RGW 기반)·shared-nothing(FE+BE3, 로컬 XFS 기반) 양쪽 클러스터 재배포, 테이블 생성/쓰기/조회로 end-to-end 확인(RGW 버킷 오브젝트 수 증가로 실제 저장 확인)
