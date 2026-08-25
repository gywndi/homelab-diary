# KVM 하이퍼바이저 인프라 (Stage 1)

Kubernetes로 옮기기 어려운 워크로드(특정 OS 필요, 컨테이너화 곤란)를 위한 대안. 실제 VM은 만들지 않고, libvirt와 스토리지 풀만 준비해둔 상태.

## 스크립트

### 1. `01-setup-libvirt.sh` — 하이퍼바이저 설치 + 스토리지 풀 등록 (양쪽 노드 동일)
qemu-kvm·libvirt-daemon-system·virtinst 설치, 작업 계정을 libvirt/kvm 그룹에 추가, `/data/vms`를 `data-pool`이라는 libvirt storage pool로 등록.
```bash
sudo ./01-setup-libvirt.sh
```

## 확인

```bash
virsh list --all          # 현재 VM 없음 (정상)
virsh pool-list --all     # data-pool  active  yes
```

## 다음 VM을 만들 때

- storage pool: `data-pool` (경로 `/data/vms`)
- 작업 계정이 `libvirt`/`kvm` 그룹에 속해 있어 `virsh`/`virt-install`을 sudo 없이 사용 가능 (그룹 적용을 위해 재로그인 필요할 수 있음)
- CPU/메모리는 k8s·MySQL과 겹치지 않게 사전 예산 배정 필요 (특정 워크로드가 정해지면 결정)
