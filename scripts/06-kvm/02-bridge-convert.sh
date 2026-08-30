#!/bin/bash
# 물리 NIC(enp1s0)을 br0 브리지로 전환한다. VM이 물리 LAN에 직접 나가려면
# (여러 물리 노드에 걸친 VM 클러스터를 만들려면 필수) NAT 전용 virbr0로는 안 되고
# 이렇게 브리지가 있어야 한다.
#
# 실패해도 90초 뒤 자동으로 원복되는 안전장치가 있다(원격 SSH로 작업하다 네트워크가
# 끊겨도 락아웃되지 않도록) — 문제없으면 아래 안내대로 직접 취소해야 한다.
#
# 이 노드에서 keepalived(k8s API VIP, Ceph RGW VIP 등)가 돌고 있다면 브리지 전환
# 후 반드시 keepalived.conf의 "interface enp1s0"을 "interface br0"으로 바꾸고
# 재시작해야 한다 — VIP가 물리 NIC이 아니라 브리지에서 뜨게 됐기 때문이다.
#
# 사용법: sudo ./02-bridge-convert.sh <이 노드의 IP>
#   예: sudo ./02-bridge-convert.sh 10.5.5.8

set -euo pipefail

IP="${1:-}"
if [[ -z "$IP" ]]; then
  echo "사용법: $0 <IP>" >&2
  exit 1
fi

CONF=/etc/netplan/50-cloud-init.yaml
BACKUP=/etc/netplan/50-cloud-init.yaml.pre-bridge-bak

echo "== 기존 설정 백업 =="
cp "$CONF" "$BACKUP"

echo "== 90초 뒤 자동 원복 예약 (문제 없으면 아래 안내대로 취소) =="
systemd-run --unit=netplan-revert --on-active=90 /bin/bash -c "cp $BACKUP $CONF && netplan apply"

echo "== 새 브리지 설정 작성 =="
cat > "$CONF" <<EOF
network:
  version: 2
  ethernets:
    enp1s0:
      dhcp4: no
  bridges:
    br0:
      interfaces: [enp1s0]
      addresses:
      - "${IP}/24"
      nameservers:
        addresses:
        - 168.126.63.1
        search: []
      routes:
      - to: "default"
        via: "10.5.5.1"
      parameters:
        stp: false
        forward-delay: 0
EOF

echo "== 적용 =="
netplan apply

echo "완료: br0 적용됨."
echo "  1) SSH/서비스 정상 확인되면: systemctl stop netplan-revert.timer"
echo "  2) keepalived를 쓰는 노드라면: sed -i 's/interface enp1s0/interface br0/' /etc/keepalived/keepalived.conf && systemctl restart keepalived"
