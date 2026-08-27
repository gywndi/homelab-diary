#!/bin/bash
# 컨트롤플레인 마무리 — Flannel CNI 설치 + 워커 join 명령 생성 (chan08 전용)
#
# 05-setup-apiserver-vip-keepalived.sh로 VIP가 뜬 "다음"에 실행한다. admin.conf가
# VIP 주소를 보고 있어서, VIP가 살아있어야 이 스크립트의 kubectl/kubeadm 명령이 동작한다.
#
# 사용법: sudo ./06-finalize-control-plane.sh

set -euo pipefail

TARGET_USER="${SUDO_USER:-$(whoami)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

export KUBECONFIG="$TARGET_HOME/.kube/config"

echo "== Flannel CNI 설치 =="
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

echo "== 워커 join 명령 저장 =="
kubeadm token create --print-join-command > "$TARGET_HOME/join-command.sh"
chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/join-command.sh"
chmod 600 "$TARGET_HOME/join-command.sh"

echo "완료: 컨트롤플레인 초기화 마무리. join 명령은 ${TARGET_HOME}/join-command.sh 에 저장됨"
