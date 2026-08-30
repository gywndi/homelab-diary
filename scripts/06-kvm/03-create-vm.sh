#!/bin/bash
# 이 노드에 Ubuntu 24.04 VM 1개를 생성한다 (br0 브리지, 실 LAN IP).
# 사전 조건: 02-bridge-convert.sh로 br0이 이미 있을 것.
# 이 노드의 chan 계정 authorized_keys(전부)를 그대로 VM에도 심는다.
#
# 사용법: sudo ./03-create-vm.sh <VM이름> <IP> <게이트웨이>
#   예: sudo ./03-create-vm.sh starrocks-vm1 10.5.5.52 10.5.5.1

set -euo pipefail

NAME="${1:-}"
IP="${2:-}"
GW="${3:-}"
if [[ -z "$NAME" || -z "$IP" || -z "$GW" ]]; then
  echo "사용법: $0 <VM이름> <IP> <게이트웨이>" >&2
  exit 1
fi

POOL_DIR="/mnt/starrocks-be/vm-disks"
IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
BASE_IMG="${POOL_DIR}/noble-server-cloudimg-amd64.img"
DISK="${POOL_DIR}/${NAME}.qcow2"
SEED="${POOL_DIR}/${NAME}-seed.iso"

echo "== 재실행 대비: 기존 동일 이름 VM 제거 =="
virsh -c qemu:///system destroy "$NAME" >/dev/null 2>&1 || true
virsh -c qemu:///system undefine "$NAME" >/dev/null 2>&1 || true

echo "== 베이스 클라우드 이미지 다운로드(캐시되면 재사용) =="
if [[ ! -f "$BASE_IMG" ]]; then
  curl -fL -o "$BASE_IMG" "$IMG_URL"
fi

echo "== VM 전용 디스크 생성 (베이스 이미지 위에 40G로 확장) =="
qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMG" "$DISK" 40G

echo "== cloud-init seed ISO 생성 =="
WORKDIR=$(mktemp -d)
cat > "$WORKDIR/user-data" <<EOF
#cloud-config
hostname: ${NAME}
manage_etc_hosts: true
users:
  - name: chan
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: sudo
    shell: /bin/bash
    ssh_authorized_keys:
$(sed 's/^/      - /' /home/chan/.ssh/authorized_keys)
package_update: true
EOF
cat > "$WORKDIR/meta-data" <<EOF
instance-id: ${NAME}
local-hostname: ${NAME}
EOF
cat > "$WORKDIR/network-config" <<EOF
version: 2
ethernets:
  enp1s0:
    addresses: [${IP}/24]
    routes:
      - to: default
        via: ${GW}
    nameservers:
      addresses: [10.5.5.2]
EOF
cloud-localds --network-config="$WORKDIR/network-config" "$SEED" "$WORKDIR/user-data" "$WORKDIR/meta-data"
rm -rf "$WORKDIR"

echo "== VM 생성 =="
virt-install \
  --connect qemu:///system \
  --name "$NAME" \
  --memory 4096 \
  --vcpus 2 \
  --disk path="$DISK",format=qcow2 \
  --disk path="$SEED",device=cdrom \
  --network bridge=br0,model=virtio \
  --os-variant ubuntu24.04 \
  --import \
  --noautoconsole \
  --graphics none

echo "완료: ${NAME} (${IP}) 생성됨. 부팅까지 30초~1분 정도 걸릴 수 있음."
