#!/bin/bash
# containerd 설치 및 systemd cgroup driver 설정
#
# 사용법: sudo ./02-containerd.sh (양쪽 노드 모두 실행)

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "== containerd 설치 =="
apt-get update -y
apt-get install -y containerd

echo "== SystemdCgroup 설정 =="
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl restart containerd
systemctl enable containerd

echo "== 확인 =="
systemctl is-active containerd
grep SystemdCgroup /etc/containerd/config.toml

echo "완료: containerd 설치"
