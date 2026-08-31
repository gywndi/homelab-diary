#!/bin/bash
# 노드를 cephadm 클러스터에 추가한다. cephadm은 SSH로 각 호스트에 데몬을
# 배포하는데, root가 아니라 chan(NOPASSWD sudo)으로 접속하도록 14번
# 스크립트에서 이미 전환해뒀다(ceph cephadm set-user chan) — 그래서 클러스터
# SSH 공개키도 root가 아니라 chan의 authorized_keys에 등록한다.
#
# 사전 조건: 14-cephadm-bootstrap.sh 완료(chan08)
# 사용법: chan08에서 실행, 대상 노드에 chan 계정으로 SSH 가능해야 함
#   sudo ./15-cephadm-add-host.sh <호스트명> <IP>
#   예: sudo ./15-cephadm-add-host.sh chan09 10.5.5.9

set -euo pipefail

HOSTNAME="${1:-}"
IP="${2:-}"
if [[ -z "$HOSTNAME" || -z "$IP" ]]; then
  echo "사용법: $0 <호스트명> <IP>" >&2
  exit 1
fi

echo "== 클러스터 SSH 공개키를 ${HOSTNAME}(${IP})의 chan 계정에 등록 =="
PUBKEY=$(cat /etc/ceph/ceph.pub)
ssh "chan@${IP}" "grep -qF '${PUBKEY}' ~/.ssh/authorized_keys 2>/dev/null || echo '${PUBKEY}' >> ~/.ssh/authorized_keys"

echo "== 클러스터에 호스트 추가 =="
cephadm shell -- ceph orch host add "$HOSTNAME" "$IP"
cephadm shell -- ceph orch host ls

echo "완료: ${HOSTNAME} 추가"
