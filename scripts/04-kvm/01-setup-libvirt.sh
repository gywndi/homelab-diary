#!/bin/bash
# KVM/libvirt 하이퍼바이저 인프라 준비 (실제 VM은 생성하지 않음)
#
# 사용법: sudo ./01-setup-libvirt.sh (양쪽 노드 모두 실행)

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# sudo로 실행해도 $HOME은 root가 되므로, 실제 로그인 계정과 그 홈 디렉터리를 따로 구한다
TARGET_USER="${SUDO_USER:-$(whoami)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

echo "== KVM/libvirt 패키지 설치 =="
apt-get update -y
apt-get install -y qemu-kvm libvirt-daemon-system libvirt-clients virtinst bridge-utils

echo "== ${TARGET_USER} 계정을 libvirt/kvm 그룹에 추가 =="
usermod -aG libvirt,kvm "$TARGET_USER"

echo "== libvirtd 활성화 =="
systemctl enable --now libvirtd

echo "== /data/vms storage pool 등록 =="
mkdir -p /data/vms
if ! virsh pool-info data-pool >/dev/null 2>&1; then
  virsh pool-define-as data-pool dir --target /data/vms
  virsh pool-build data-pool
  virsh pool-start data-pool
  virsh pool-autostart data-pool
fi

echo "== ${TARGET_USER} 계정 기본 libvirt URI를 qemu:///system으로 고정 =="
# 이 계정으로 virsh를 sudo 없이 실행하면 기본값이 qemu:///session(사용자별,
# 이 storage pool과 무관한 별도 인스턴스)이라 -c 없이는 이 pool이 안 보인다.
mkdir -p "$TARGET_HOME/.config/libvirt"
cat > "$TARGET_HOME/.config/libvirt/libvirt.conf" <<EOF
uri_default = "qemu:///system"
EOF
chown -R "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.config/libvirt"

echo "== 확인 =="
virsh list --all
virsh pool-list --all
lsmod | grep kvm

echo "완료: KVM/libvirt 인프라 준비 (VM은 생성하지 않음)"
