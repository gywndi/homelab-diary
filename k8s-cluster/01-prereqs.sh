#!/bin/bash
# k8s 사전 준비: swap 비활성화, 커널 모듈, sysctl
#
# 사용법: sudo ./01-prereqs.sh (양쪽 노드 모두 실행)

set -euo pipefail

echo "== swap 비활성화 =="
swapoff -a
sed -i.bak -E '/\sswap\s/ s/^([^#])/#\1/' /etc/fstab

echo "== 커널 모듈 로드 =="
modprobe overlay
modprobe br_netfilter

cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

echo "== sysctl 설정 =="
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system > /dev/null

echo "== 확인 =="
free -h | grep Swap
lsmod | grep -E "overlay|br_netfilter"

echo "완료: k8s 사전 준비"
