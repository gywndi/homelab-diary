#!/bin/bash
# Ceph(Rook, hostNetwork) 방화벽 포트 개방 — chan08/chan09/llm001 3노드 모두에서 실행
#
# hostNetwork 배포라 mon/mgr/osd가 pod network가 아니라 노드 IP에 직접 바인딩된다.
# KVM/libvirt가 pod network 밖(호스트)에서 이 포트로 직접 접근해야 하므로 필수.
#
# 사용법: sudo ./00-open-ceph-firewall-ports.sh

set -euo pipefail

SUBNET="10.5.5.0/24"
# k8s API 서버 때와 같은 same-node hairpin 문제: 같은 노드의 pod network(non-hostNetwork)
# 파드가 이 노드의 hostNetwork Ceph 데몬에 접근할 때 소스 IP가 10.5.5.0/24가 아니라
# pod CIDR이라 위 SUBNET 규칙에 안 걸린다. toolbox/csi-plugin/rgw 파드가 실제로 이 경로를
# 타므로 반드시 필요 (누락 시 rados/radosgw-admin 명령이 타임아웃 없이 그냥 멈춘다).
POD_CIDR="10.244.0.0/16"

echo "== mon (msgr v1/v2) =="
ufw allow from "$SUBNET" to any port 6789 proto tcp comment 'Ceph mon msgr v1'
ufw allow from "$SUBNET" to any port 3300 proto tcp comment 'Ceph mon msgr v2'
ufw allow from "$POD_CIDR" to any port 6789 proto tcp comment 'Ceph mon msgr v1 same-node hairpin'
ufw allow from "$POD_CIDR" to any port 3300 proto tcp comment 'Ceph mon msgr v2 same-node hairpin'

echo "== osd/mgr/mds 포트 범위 =="
ufw allow from "$SUBNET" to any port 6800:7300 proto tcp comment 'Ceph osd/mgr/mds'
ufw allow from "$POD_CIDR" to any port 6800:7300 proto tcp comment 'Ceph osd/mgr/mds same-node hairpin'

echo "== mgr 대시보드(ssl) =="
ufw allow from "$SUBNET" to any port 8443 proto tcp comment 'Ceph mgr dashboard'
ufw allow from "$POD_CIDR" to any port 8443 proto tcp comment 'Ceph mgr dashboard same-node hairpin'

echo "== RGW(S3, StarRocks용) =="
ufw allow from "$SUBNET" to any port 7480 proto tcp comment 'Ceph RGW S3'
ufw allow from "$POD_CIDR" to any port 7480 proto tcp comment 'Ceph RGW S3 same-node hairpin'

ufw reload

echo "== 확인 =="
ufw status verbose

echo "완료: Ceph 방화벽 포트 추가"
