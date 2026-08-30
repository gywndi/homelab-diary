#!/bin/bash
# Ceph(cephadm, 베어메탈) 방화벽 포트 개방 — chan08/chan09/llm001 3노드 모두에서 실행
#
# 물리 LAN(10.5.5.0/24)에서만 허용한다. cephadm 데몬은 k8s pod network와 무관하게
# 노드 IP에 직접 뜨므로, Rook 시절 hostNetwork 파드에 필요했던 pod-CIDR(same-node
# hairpin) 예외 규칙은 더 이상 필요 없다 — k8s에서 오는 트래픽(ceph-csi 등)도 노드를
# 거쳐 일반 라우팅으로 들어온다.
#
# 사용법: sudo ./00-open-ceph-firewall-ports.sh

set -euo pipefail

echo "== mon (msgr v1/v2) =="
ufw allow from 10.5.5.0/24 to any port 6789 proto tcp comment 'Ceph mon msgr v1'
ufw allow from 10.5.5.0/24 to any port 3300 proto tcp comment 'Ceph mon msgr v2'

echo "== osd/mgr/mds 포트 범위 =="
ufw allow from 10.5.5.0/24 to any port 6800:7300 proto tcp comment 'Ceph osd/mgr/mds'

echo "== mgr 대시보드(ssl) =="
ufw allow from 10.5.5.0/24 to any port 8443 proto tcp comment 'Ceph mgr dashboard'

echo "== RGW(S3, StarRocks용) =="
ufw allow from 10.5.5.0/24 to any port 7480 proto tcp comment 'Ceph RGW S3'

ufw reload

echo "== 확인 =="
ufw status verbose

echo "완료: Ceph 방화벽 포트 추가"
