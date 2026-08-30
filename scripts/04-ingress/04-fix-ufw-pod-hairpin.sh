#!/bin/bash
# 컨트롤플레인 노드에 파드가 처음 뜨면 걸리는 방화벽 문제 해결.
#
# 같은 노드의 파드가 그 노드 자신의 IP(예: API 서버 6443)로 접속하면
# kube-proxy가 소스 IP를 마스커레이드하지 않아 파드 서브넷 IP가 그대로
# 노출되는데, UFW는 지금까지 물리 LAN 대역만 허용해왔어서 INPUT 체인에서
# 막힌다. 파드 서브넷(Flannel 기본 10.244.0.0/16)을 API 서버 포트에
# 허용해서 해결한다.
#
# 사용법: (해당 노드에 직접 로그인해서)
#   ./04-fix-ufw-pod-hairpin.sh

set -euo pipefail

sudo ufw allow from 10.244.0.0/16 to any port 6443 proto tcp comment 'pod-to-apiserver same-node hairpin'

echo "== 확인 =="
sudo ufw status | grep 6443
