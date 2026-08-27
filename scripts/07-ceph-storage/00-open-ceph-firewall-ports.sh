#!/bin/bash
# Ceph(Rook, hostNetwork) 방화벽 포트 개방 — chan08/chan09/llm001 3노드 모두에서 실행
#
# hostNetwork 배포라 mon/mgr/osd가 pod network가 아니라 노드 IP에 직접 바인딩된다.
# KVM/libvirt가 pod network 밖(호스트)에서 이 포트로 직접 접근해야 하므로 필수.
#
# 사용법: sudo ./00-open-ceph-firewall-ports.sh

set -euo pipefail

SUBNET="10.5.5.0/24"

echo "== mon (msgr v1/v2) =="
ufw allow from "$SUBNET" to any port 6789 proto tcp comment 'Ceph mon msgr v1'
ufw allow from "$SUBNET" to any port 3300 proto tcp comment 'Ceph mon msgr v2'

echo "== osd/mgr/mds 포트 범위 =="
ufw allow from "$SUBNET" to any port 6800:7300 proto tcp comment 'Ceph osd/mgr/mds'

echo "== mgr 대시보드(ssl) =="
ufw allow from "$SUBNET" to any port 8443 proto tcp comment 'Ceph mgr dashboard'

echo "== RGW(S3, StarRocks용) =="
ufw allow from "$SUBNET" to any port 7480 proto tcp comment 'Ceph RGW S3'

ufw reload

echo "== 확인 =="
ufw status verbose

echo "완료: Ceph 방화벽 포트 추가"
