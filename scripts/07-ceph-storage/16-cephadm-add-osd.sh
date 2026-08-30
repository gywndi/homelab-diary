#!/bin/bash
# 노드의 Ceph 전용 파티션을 OSD로 등록한다.
# cephadm의 표준 경로(`ceph orch daemon add osd`)는 raw 파티션을 직접 못 받는다
# ("please pass LVs or raw block devices") — LVM 논리 볼륨으로 한 겹 감싸서 넘긴다.
#
# 사전 조건: 대상 노드가 15-cephadm-add-host.sh로 이미 추가돼 있을 것,
#            대상 파티션은 Ceph 전용으로 비어있을 것(기존 시그니처 있으면 wipefs 먼저)
# 사용법: chan08에서 실행
#   sudo ./16-cephadm-add-osd.sh <호스트명> <IP> <파티션, 예: /dev/sda1>
#   예: sudo ./16-cephadm-add-osd.sh chan08 10.5.5.8 /dev/sda1

set -euo pipefail

HOSTNAME="${1:-}"
IP="${2:-}"
PARTITION="${3:-}"
if [[ -z "$HOSTNAME" || -z "$IP" || -z "$PARTITION" ]]; then
  echo "사용법: $0 <호스트명> <IP> <파티션>" >&2
  exit 1
fi

echo "== ${HOSTNAME}(${IP})의 ${PARTITION}을 LVM 논리 볼륨으로 감싸기 =="
ssh "chan@${IP}" "sudo pvcreate ${PARTITION} && sudo vgcreate ceph-osd-vg ${PARTITION} && sudo lvcreate -l 100%FREE -n osd-data ceph-osd-vg"

echo "== OSD로 등록 =="
cephadm shell -- ceph orch daemon add osd "${HOSTNAME}:/dev/ceph-osd-vg/osd-data"

echo "완료: ${HOSTNAME}의 ${PARTITION}을 OSD로 등록"
