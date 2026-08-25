#!/bin/bash
# 컨트롤플레인 초기화 + Flannel CNI 설치 (chan08 전용)
#
# 사용법: sudo ./04-init-control-plane.sh

set -euo pipefail

ADVERTISE_IP="10.5.5.8"
POD_CIDR="10.244.0.0/16"

echo "== kubeadm init =="
kubeadm init \
  --apiserver-advertise-address="$ADVERTISE_IP" \
  --pod-network-cidr="$POD_CIDR" \
  | tee /root/kubeadm-init.log

echo "== chan 계정용 kubeconfig 설정 =="
mkdir -p /home/chan/.kube
cp -i /etc/kubernetes/admin.conf /home/chan/.kube/config
chown chan:chan /home/chan/.kube/config /home/chan/.kube

export KUBECONFIG=/home/chan/.kube/config

echo "== Flannel CNI 설치 =="
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

echo "== 워커 join 명령 저장 =="
kubeadm token create --print-join-command > /home/chan/join-command.sh
chown chan:chan /home/chan/join-command.sh
chmod 600 /home/chan/join-command.sh

echo "완료: 컨트롤플레인 초기화. join 명령은 /home/chan/join-command.sh 에 저장됨"
