# KVM 하이퍼바이저 인프라

[← 이전: LLM GPU 노드](05-llm-gpu-node.md) · [다음: Ceph 스토리지 →](07-1-ceph-storage.md)

Kubernetes로 옮기기 어려운 워크로드를 위한 대안. 3노드(chan08/chan09/llm001) 전부에 libvirt와 전용 스토리지 풀, VM 간 실 LAN 통신용 브리지를 갖춰뒀다. 이 문서는 인프라 자체(하이퍼바이저·스토리지 풀·브리지·VM 생성)만 다룬다 — 이 위에서 돌리는 실제 워크로드는 별도 유즈케이스 문서다(예: [StarRocks 베어메탈 구축](08-2-starrocks-baremetal.md)).

## 목적

컨테이너화가 어려운 워크로드를 위해 KVM 하이퍼바이저 기반을 갖춘다. 특정 OS가 필요하거나 그대로 옮기기 곤란한 경우가 대상이다. VM이 물리 노드를 넘나들며 서로 통신해야 하는 경우(예: 여러 노드에 걸친 클러스터)를 대비해, NAT 전용 기본 네트워크가 아니라 물리 LAN에 직접 붙는 브리지까지 준비해둔다. 이 문서 자체는 특정 워크로드를 가정하지 않는다 — "VM을 어디에 어떻게 띄울 수 있는가"까지가 범위고, 그 위에 무엇을 올릴지는 각 유즈케이스 문서 몫이다.

## 대상 노드

| 노드 | IP | 비고 |
|---|---|---|
| chan08 | 10.5.5.8 | |
| chan09 | 10.5.5.9 | |
| llm001 | 10.5.5.10 | GPU 노드, 원래부터 br0(`enp12s0` 기반)를 쓰고 있었음 — [`05-llm-gpu-node.md`](05-llm-gpu-node.md) 참고 |

## 설계 결정

- **VM 디스크는 libvirt 스토리지 풀(storage pool)로 등록한 XFS 파티션(`/mnt/local-data`) 위에.** libvirt는 디스크 이미지를 아무 경로에나 직접 만들 수도 있지만, 그러면 `virsh vol-list`/용량 조회/재부팅 시 자동 마운트 같은 라이프사이클 관리를 libvirt가 못 한다 — 경로 하나를 "풀"로 등록해두면 그 안의 이미지 파일들을 libvirt가 볼륨으로 추적해준다. 원래는 전용 `/data/vms` 파티션을 쓸 계획이었으나, Ceph 도입 과정에서 그 파티션 자체가 재분할돼 없어졌다(아래 "알려진 이슈" 참고). 남은 로컬 XFS 파티션의 여유 공간(노드당 400G 이상)을 그대로 쓴다 — Ceph RBD로 옮기는 방안도 검토했지만([`07-1-ceph-storage.md`](07-1-ceph-storage.md) 설계 결정 참고), VM은 실험적 용도라 설정 단계를 하나 더 늘릴 이유가 약했다.
- **물리 NIC을 브리지로 바꾼다.** libvirt 기본 네트워크(`virbr0`)는 NAT다 — 그 안의 VM은 사설 대역(예: `192.168.122.0/24`) IP를 받고, 밖으로 나가는 트래픽만 호스트가 대신 주소변환(MASQUERADE)해준다. 그래서 이 VM은 물리 LAN의 다른 호스트가 먼저 IP로 접속해올 수 없고, 다른 물리 노드 위의 VM과도 서로 직접 통신할 수 없다(둘 다 서로에게 안 보이는 사설 네트워크에 있으므로). 여러 노드에 걸친 VM 클러스터를 만들려면 VM이 실제 LAN IP(`10.5.5.0/24`)를 직접 받아야 하므로, 노드의 유일한 물리 NIC(`enp1s0`)를 브리지(`br0`)로 바꾸고 VM을 거기에 붙인다 — 브리지는 NIC과 VM의 가상 NIC을 같은 이더넷 세그먼트로 묶어, VM이 물리 스위치에 직접 연결된 것처럼 동작하게 한다.
- **브리지 전환은 dead-man's-switch로 안전하게.** 원격 SSH로 노드의 유일한 NIC 설정을 바꾸는 작업이라, 잘못되면 그 노드에 완전히 접속이 끊길 위험이 있다. `systemd-run`으로 "N초 뒤 자동 원복" 타이머를 미리 걸어두고, 새 설정을 적용한 뒤 접속이 살아있는 걸 확인하고서야 그 타이머를 취소하는 방식을 쓴다.
- **VM은 cloud-init(NoCloud)으로 완전 자동 프로비저닝한다.** 콘솔로 손수 OS 설치 마법사를 거치면 VM마다 사람이 붙어 있어야 하고, 여러 대를 동일하게 맞추기도 번거롭다. 대신 Ubuntu 클라우드 이미지를 그대로 백킹 디스크로 쓰고, `cloud-localds`로 만든 seed ISO(가상 CD-ROM처럼 VM에 물려서 첫 부팅 시 cloud-init이 읽는 설정 이미지)에 계정/SSH 키/고정 IP를 심어서 최초 부팅부터 SSH가 바로 되게 한다.

## 스크립트 목록 (이름 순)

### 하이퍼바이저 설치 + 스토리지 풀 등록
- 설명: 하이퍼바이저를 설치하고 스토리지 풀을 등록한다 (3노드 전부).
- 스크립트: [`01-setup-libvirt.sh`](../scripts/06-kvm/01-setup-libvirt.sh)
```bash
# 하이퍼바이저(qemu-kvm)와 관리 데몬(libvirt), VM 생성 도구 설치
sudo apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients virtinst bridge-utils

# 작업 계정(chan)을 libvirt/kvm 그룹에 추가 (sudo 없이 virsh 사용 가능)
sudo usermod -aG libvirt,kvm chan

# libvirt 데몬 활성화 + 즉시 시작
sudo systemctl enable --now libvirtd

# 남은 XFS 파티션 위에 vm-pool이라는 이름의 저장 공간 등록 (이미 등록돼 있으면 건너뜀)
sudo mkdir -p /mnt/local-data/vm-disks
sudo virsh pool-define-as vm-pool dir --target /mnt/local-data/vm-disks
sudo virsh pool-build vm-pool
sudo virsh pool-start vm-pool
sudo virsh pool-autostart vm-pool
```
`virsh`를 sudo 없이 실행하면 기본 연결 대상이 `qemu:///session`(계정별 개인 인스턴스, 위 storage pool과 무관)이라 `-c` 없이는 이 pool이 안 보인다. 그래서 이 계정의 기본 연결 대상도 명시적으로 고정한다.
```bash
mkdir -p /home/chan/.config/libvirt
cat > /home/chan/.config/libvirt/libvirt.conf <<EOF
uri_default = "qemu:///system"
EOF
sudo chown -R chan:chan /home/chan/.config/libvirt
```

### 물리 NIC을 브리지로 전환
- 설명: `enp1s0`을 `br0`으로 바꿔 VM이 물리 LAN에 직접 나가게 한다 (chan08/chan09 — llm001은 이미 보유). keepalived가 도는 노드라면 인터페이스 참조도 같이 바꿔야 한다.
- 스크립트: [`02-bridge-convert.sh`](../scripts/06-kvm/02-bridge-convert.sh)
```bash
sudo ./02-bridge-convert.sh 10.5.5.8
```
netplan 안에서 일어나는 일(핵심):
```yaml
network:
  version: 2
  ethernets:
    enp1s0:
      dhcp4: no
  bridges:
    br0:
      interfaces: [enp1s0]
      addresses: ["10.5.5.8/24"]
      routes:
        - to: "default"
          via: "10.5.5.1"
```
적용 후 확인되면 자동원복 타이머부터 취소하고, keepalived가 있으면 인터페이스를 갱신한다:
```bash
# 접속 정상 확인되면 자동원복 취소
sudo systemctl stop netplan-revert.timer

# keepalived를 쓰는 노드라면 (k8s API VIP, Ceph RGW VIP 등)
sudo sed -i 's/interface enp1s0/interface br0/' /etc/keepalived/keepalived.conf
sudo systemctl restart keepalived
```

### VM 생성
- 설명: Ubuntu 24.04 VM 1개를 만든다. cloud-init으로 계정/SSH 키/고정 IP까지 자동 설정된다. 이름/IP/게이트웨이만 받는 범용 스크립트라 워크로드를 가리지 않는다 — 실제로 이 스크립트로 만든 VM들의 구체적인 값과 그 위에 올린 워크로드는 [StarRocks 베어메탈 구축](08-2-starrocks-baremetal.md) 참고.
- 스크립트: [`03-create-vm.sh`](../scripts/06-kvm/03-create-vm.sh)
```bash
sudo ./03-create-vm.sh <VM이름> <IP> <게이트웨이>
```
핵심 부분(전체는 스크립트 참고):
```bash
# 클라우드 이미지를 백킹 디스크로 40G만큼 씀 (원본 이미지는 안 바뀜, copy-on-write)
qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMG" "$DISK" 40G

# cloud-init seed ISO 생성 (계정/SSH 키/고정 IP)
cloud-localds --network-config="$WORKDIR/network-config" "$SEED" "$WORKDIR/user-data" "$WORKDIR/meta-data"

# br0에 붙여서 VM 생성 (콘솔 없이, 이미지 그대로 임포트)
virt-install --connect qemu:///system --name "$NAME" \
  --memory 4096 --vcpus 2 \
  --disk path="$DISK",format=qcow2 --disk path="$SEED",device=cdrom \
  --network bridge=br0,model=virtio \
  --os-variant ubuntu24.04 --import --noautoconsole --graphics none
```
SSH 키는 이 노드(호스트)의 `/home/chan/.ssh/authorized_keys`를 그대로 복사해 넣는다 — `sudo`로 스크립트를 실행하면 `$HOME`이 `/root`로 바뀌므로 `~`가 아니라 절대 경로로 명시해야 한다(안 그러면 `/root/.ssh/authorized_keys`의 다른 키가 들어가서 접속이 안 된다).

## 알려진 이슈

### 스토리지 풀 경로가 애초 계획과 달라짐
전용 `/data` 파티션(`data-pool`)을 쓸 계획이었으나, Ceph를 cephadm으로 재구축하며 디스크가 재분할돼 `/data` 마운트 자체가 사라졌다(`sda1`=Ceph OSD LVM, `sda2`=`/mnt/local-data`). 남은 XFS 파티션(`/mnt/local-data/vm-disks`)으로 스토리지 풀 경로를 다시 잡았다.

### VM 재생성 시 known_hosts 충돌
같은 이름으로 VM을 파괴 후 재생성하면 SSH 호스트 키가 바뀌어, 관리 머신 `known_hosts`에 남은 이전 키 때문에 "REMOTE HOST IDENTIFICATION HAS CHANGED" 경고와 함께 접속이 거부된다 — `ssh-keygen -R <IP>`로 예전 항목을 지우고 재접속하면 된다.

### cloud-init 자격증명 첫 줄만 넣으면 틀릴 수 있다
`authorized_keys`에 키가 여러 개 있을 때 `head -1`로 첫 줄만 넣으면 지금 실제로 쓰는 키가 아닐 수 있어 접속이 안 된다. 파일 안의 키를 전부 넣는 쪽이 안전하다(현재 스크립트는 이렇게 되어 있음).

## 검증 명령

```bash
# 스토리지 풀 상태 (vm-pool이 active여야 함)
virsh pool-list --all

# VM 목록/상태
virsh list --all

# br0에 실제로 노드 IP가 올라와 있는지
ip -4 addr show br0

# VM이 SSH로 붙는지 (IP는 cloud-init에 준 고정 IP)
ssh chan@<VM IP> hostname
```

---

[← 이전: LLM GPU 노드](05-llm-gpu-node.md) · [다음: Ceph 스토리지 →](07-1-ceph-storage.md)
