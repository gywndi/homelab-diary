#!/bin/bash
# 컨트롤플레인 초기화 (chan08 전용)
#
# --control-plane-endpoint를 처음부터 VIP로 지정해서 시작한다. 이 VIP는 아직 이
# 스크립트를 실행하는 시점엔 실제로 떠 있지 않지만(다음 단계인
# 05-setup-apiserver-vip-keepalived.sh에서 띄움) 상관없다 — kubeadm은 이 값을
# 인증서 SAN과 클러스터 설정에 "박아 넣기"만 할 뿐, init 도중에 그 주소로
# 접속을 시도하지는 않는다. 대신 kubeadm이 자동 생성하는 admin.conf(kubectl 설정)의
# 접속 주소가 이 VIP로 고정되므로, kubectl은 VIP가 뜬 다음에야 정상 동작한다.
# 그래서 flannel 설치·join 명령 생성은 이 스크립트가 아니라 06-finalize-control-plane.sh에서
# (VIP가 뜬 뒤에) 한다 — 왜 이 순서여야 하는지는 lessons/02-k8s-cluster.md 참고.
#
# 사용법: sudo ./04-init-control-plane.sh

set -euo pipefail

ADVERTISE_IP="10.5.5.8"
VIP="10.5.5.3"
POD_CIDR="10.244.0.0/16"

# sudo로 실행해도 $HOME은 root가 되므로, 실제 로그인 계정과 그 홈 디렉터리를 따로 구한다
TARGET_USER="${SUDO_USER:-$(whoami)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

echo "== kubeadm init (controlPlaneEndpoint=${VIP}:6443) =="
kubeadm init \
  --apiserver-advertise-address="$ADVERTISE_IP" \
  --control-plane-endpoint="${VIP}:6443" \
  --upload-certs \
  --pod-network-cidr="$POD_CIDR" \
  | tee /root/kubeadm-init.log

echo "== ${TARGET_USER} 계정용 kubeconfig 설정 (server 주소는 위 VIP로 자동 설정됨) =="
mkdir -p "$TARGET_HOME/.kube"
cp -i /etc/kubernetes/admin.conf "$TARGET_HOME/.kube/config"
chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/.kube/config" "$TARGET_HOME/.kube"

echo "완료: 컨트롤플레인 초기화. 다음은 05-setup-apiserver-vip-keepalived.sh로 VIP를 띄울 것"
echo "(그 전까지는 kubectl이 ${VIP}에 붙지 못해 정상 동작하지 않는다 - 의도된 상태)"
