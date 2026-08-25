# KVM 하이퍼바이저 인프라 (Stage 1)

Kubernetes로 옮기기 어려운 워크로드(특정 OS 필요, 컨테이너화 곤란)를 위한 대안. 실제 VM은 만들지 않고, libvirt와 스토리지 풀만 준비해둔 상태.

## 스크립트 목록 (이름 순)

### 하이퍼바이저 설치 + 스토리지 풀 등록
설명: 하이퍼바이저를 설치하고 스토리지 풀을 등록한다 (양쪽 노드 동일).
스크립트: [`01-setup-libvirt.sh`](../scripts/04-kvm/01-setup-libvirt.sh)
```bash
# 하이퍼바이저(qemu-kvm)와 관리 데몬(libvirt), VM 생성 도구 설치
sudo apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients virtinst bridge-utils

# 작업 계정을 libvirt/kvm 그룹에 추가 (sudo 없이 virsh 사용 가능)
sudo usermod -aG libvirt,kvm chan

# libvirt 데몬 활성화 + 즉시 시작
sudo systemctl enable --now libvirtd

# /data/vms 디렉터리를 data-pool이라는 이름의 저장 공간으로 등록
sudo virsh pool-define-as data-pool dir --target /data/vms

# 등록한 저장 공간을 실제로 생성
sudo virsh pool-build data-pool

# 저장 공간을 사용 가능한 상태로 시작
sudo virsh pool-start data-pool

# 재부팅해도 자동으로 다시 시작되도록 설정
sudo virsh pool-autostart data-pool
```

## 확인

```bash
# 현재 VM 목록 확인 (없는 게 정상)
virsh list --all

# 스토리지 풀 상태 확인 (data-pool이 active여야 함)
virsh pool-list --all
```

## 다음 VM을 만들 때

- storage pool: `data-pool` (경로 `/data/vms`)
- 작업 계정이 `libvirt`/`kvm` 그룹에 속해 있어 `virsh`/`virt-install`을 sudo 없이 사용 가능 (그룹 적용을 위해 재로그인 필요할 수 있음)
- CPU/메모리는 k8s·MySQL과 겹치지 않게 사전 예산 배정 필요 (특정 워크로드가 정해지면 결정)
