#!/bin/bash
# UFW 방화벽 설정 - Kubernetes 클러스터 노드용
# 내부 대역(10.5.5.0/24)에서만 접근 허용, 그 외 인바운드는 기본 차단
#
# 사용법: sudo ./04-firewall.sh
#
# 주의: 컨트롤플레인/워커 역할이 아직 정해지지 않아 필요한 포트를 모두
# 열어두었습니다. 실제 역할과 CNI(Calico/Flannel 등)가 정해지면
# 사용하지 않는 포트는 제거하세요.

set -euo pipefail

SUBNET="10.5.5.0/24"

echo "== UFW 기본 정책: 인바운드 차단, 아웃바운드 허용 =="
ufw default deny incoming
ufw default allow outgoing

echo "== SSH ($SUBNET 에서만 허용) =="
ufw allow from "$SUBNET" to any port 22 proto tcp comment 'SSH'

echo "== Kubernetes API server =="
ufw allow from "$SUBNET" to any port 6443 proto tcp comment 'k8s API server'

echo "== etcd =="
ufw allow from "$SUBNET" to any port 2379:2380 proto tcp comment 'etcd'

echo "== kubelet API =="
ufw allow from "$SUBNET" to any port 10250 proto tcp comment 'kubelet API'

echo "== kube-scheduler / kube-controller-manager (secure ports) =="
ufw allow from "$SUBNET" to any port 10257 proto tcp comment 'kube-controller-manager'
ufw allow from "$SUBNET" to any port 10259 proto tcp comment 'kube-scheduler'

echo "== NodePort Services =="
ufw allow from "$SUBNET" to any port 30000:32767 proto tcp comment 'NodePort'

echo "== CNI (Calico BGP / VXLAN, Flannel VXLAN - 사용하는 것만 남기고 정리 권장) =="
ufw allow from "$SUBNET" to any port 179 proto tcp comment 'Calico BGP'
ufw allow from "$SUBNET" to any port 4789 proto udp comment 'Calico VXLAN'
ufw allow from "$SUBNET" to any port 8472 proto udp comment 'Flannel VXLAN'

echo "== UFW 활성화 =="
ufw --force enable

echo "== 상태 확인 =="
ufw status verbose

echo "완료: 방화벽 설정 ($SUBNET 만 허용)"
