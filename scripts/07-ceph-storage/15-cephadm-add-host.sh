#!/bin/bash
# 노드를 cephadm 클러스터에 추가한다. cephadm은 root로 SSH 접속해 각 호스트에
# 데몬을 배포하므로, 클러스터 SSH 공개키를 대상 호스트의 root authorized_keys에
# 먼저 넣어야 한다.
#
# 사전 조건: 14-cephadm-bootstrap.sh 완료(chan08)
# 사용법: chan08에서 실행, 대상 노드에 root로 키 등록 가능해야 함
#   sudo ./15-cephadm-add-host.sh <호스트명> <IP>
#   예: sudo ./15-cephadm-add-host.sh chan09 10.5.5.9

set -euo pipefail

HOSTNAME="${1:-}"
IP="${2:-}"
if [[ -z "$HOSTNAME" || -z "$IP" ]]; then
  echo "사용법: $0 <호스트명> <IP>" >&2
  exit 1
fi

echo "== 클러스터 SSH 공개키를 ${HOSTNAME}(${IP})의 root에 등록 =="
PUBKEY=$(cat /etc/ceph/ceph.pub)
ssh "chan@${IP}" "sudo mkdir -p /root/.ssh && echo '${PUBKEY}' | sudo tee -a /root/.ssh/authorized_keys > /dev/null && sudo chmod 700 /root/.ssh && sudo chmod 600 /root/.ssh/authorized_keys"

echo "== 클러스터에 호스트 추가 =="
cephadm shell -- ceph orch host add "$HOSTNAME" "$IP"
cephadm shell -- ceph orch host ls

echo "완료: ${HOSTNAME} 추가"
