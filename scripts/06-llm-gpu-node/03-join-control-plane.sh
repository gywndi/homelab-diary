#!/bin/bash
# 새 노드를 워커가 아니라 컨트롤플레인(추가 apiserver+etcd 멤버)으로 합류
#
# 클러스터가 처음부터 VIP를 controlPlaneEndpoint로 잡고 시작했다면(02-k8s-cluster 참고)
# 이 노드가 새로 받는 join 명령도 이미 VIP를 가리키고 있어서, 아래 join만으로 충분하다
# (ClusterConfiguration을 손대거나 인증서를 재발급할 필요 없음).
#
# 사용법: sudo ./03-join-control-plane.sh <join-command 파일 경로> <이 노드의 IP>
# 사전 조건:
#   - 기존 컨트롤플레인에서 아래 두 명령으로 join 정보를 미리 받아 파일로 저장해둘 것
#       kubeadm token create --print-join-command   > join-command.sh
#       sudo kubeadm init phase upload-certs --upload-certs   (출력된 certificate-key를 join-command.sh 끝에 이어붙임)
#   - 이 노드가 이미 워커 등으로 join되어 있었다면 먼저 kubeadm reset -f로 초기화할 것
#     (drain은 자동화 도구가 위험 동작으로 차단할 수 있어, 필요하면 non-daemonset
#      파드만 개별 kubectl delete pod로 수동 대피시킨 뒤 진행)
#   - join 후에는 이 노드에도 API 서버 VIP를 나눠 가지도록
#     ../02-k8s-cluster/05-setup-apiserver-vip-keepalived.sh를 BACKUP으로 실행할 것

set -euo pipefail

JOIN_SCRIPT="${1:-}"
SELF_IP="${2:-}"

if [[ -z "$JOIN_SCRIPT" || -z "$SELF_IP" ]]; then
  echo "사용법: $0 <join-command 파일 경로> <이 노드의 IP>" >&2
  exit 1
fi

if [[ ! -f "$JOIN_SCRIPT" ]]; then
  echo "오류: $JOIN_SCRIPT 가 없습니다." >&2
  exit 1
fi

JOIN_CMD="$(cat "$JOIN_SCRIPT")"
eval "$JOIN_CMD --control-plane --apiserver-advertise-address=${SELF_IP}"

echo "완료: 컨트롤플레인으로 join. 기존 컨트롤플레인에서 'kubectl uncordon <이 노드>'와"
echo "etcd 멤버 수 확인('kubectl -n kube-system exec etcd-<기존노드> -- etcdctl member list ...') 필요"
