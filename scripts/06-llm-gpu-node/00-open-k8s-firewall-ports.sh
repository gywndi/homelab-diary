#!/bin/bash
# 이미 다른 용도로 쓰던 UFW 호스트에 k8s 컨트롤플레인+워커 포트를 추가
# (01-provision/04-firewall.sh를 거치지 않고 편입되는 기존 서버용)
#
# 기존 규칙은 그대로 두고 k8s에 필요한 포트만 추가한다.
#
# 사용법: sudo ./00-open-k8s-firewall-ports.sh

set -euo pipefail

SUBNET="10.5.5.0/24"

echo "== kubelet API =="
ufw allow from "$SUBNET" to any port 10250 proto tcp comment 'kubelet API'

echo "== NodePort =="
ufw allow from "$SUBNET" to any port 30000:32767 proto tcp comment 'NodePort'

echo "== Flannel VXLAN =="
ufw allow from "$SUBNET" to any port 8472 proto udp comment 'Flannel VXLAN'

echo "== k8s API server =="
ufw allow from "$SUBNET" to any port 6443 proto tcp comment 'k8s API server'

echo "== etcd =="
ufw allow from "$SUBNET" to any port 2379:2380 proto tcp comment 'etcd'

echo "== kube-controller-manager / kube-scheduler =="
ufw allow from "$SUBNET" to any port 10257 proto tcp comment 'kube-controller-manager'
ufw allow from "$SUBNET" to any port 10259 proto tcp comment 'kube-scheduler'

echo "== keepalived VRRP (컨트롤플레인 API VIP) =="
ufw allow from "$SUBNET" proto vrrp comment 'keepalived VRRP (컨트롤플레인 API VIP)'

echo "== MetalLB memberlist (speaker 간 리더 선출용 가십 프로토콜) =="
ufw allow from "$SUBNET" to any port 7946 proto tcp comment 'MetalLB memberlist'
ufw allow from "$SUBNET" to any port 7946 proto udp comment 'MetalLB memberlist'

ufw reload

echo "== 확인 =="
ufw status verbose

echo "완료: k8s 방화벽 포트 추가"
