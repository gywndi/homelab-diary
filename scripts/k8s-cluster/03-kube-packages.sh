#!/bin/bash
# kubeadm/kubelet/kubectl 설치 (dl.k8s.io stable 채널 기준 자동으로 최신 안정 마이너 버전 사용)
#
# 사용법: sudo ./03-kube-packages.sh (양쪽 노드 모두 실행)

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

STABLE_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
KUBE_MINOR=$(echo "$STABLE_VERSION" | grep -oE '^v[0-9]+\.[0-9]+')
echo "== 설치할 Kubernetes 버전: $STABLE_VERSION (repo: $KUBE_MINOR) =="

apt-get update -y
apt-get install -y apt-transport-https ca-certificates curl gpg

mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBE_MINOR}/deb/Release.key" \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBE_MINOR}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list

apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

echo "== 확인 =="
kubeadm version
kubelet --version
kubectl version --client

echo "완료: kubeadm/kubelet/kubectl 설치"
