#!/bin/bash
# 1TB 데이터 디스크를 XFS로 포맷하고 /data 에 마운트
#
# 사용법: sudo ./01-format-mount-data.sh /dev/sdaX
#
# 주의: 지정한 파티션의 데이터는 전부 삭제됩니다.
#   10.5.5.8 : /dev/sda2  (sda1은 1M 예약 파티션이므로 건드리지 않음)
#   10.5.5.9 : /dev/sda1  (디스크 전체가 단일 파티션)

set -euo pipefail

DEVICE="${1:-}"
MOUNT_POINT="/data"

if [[ -z "$DEVICE" ]]; then
  echo "사용법: $0 /dev/sdaX" >&2
  exit 1
fi

if [[ ! -b "$DEVICE" ]]; then
  echo "오류: $DEVICE 는 블록 디바이스가 아닙니다." >&2
  exit 1
fi

if mount | grep -q "^$DEVICE "; then
  echo "오류: $DEVICE 는 이미 마운트되어 있습니다." >&2
  exit 1
fi

echo "== $DEVICE 를 XFS로 포맷합니다 (모든 데이터 삭제) =="
mkfs.xfs -f "$DEVICE"

echo "== $MOUNT_POINT 마운트 포인트 생성 =="
mkdir -p "$MOUNT_POINT"

UUID=$(blkid -s UUID -o value "$DEVICE")
if [[ -z "$UUID" ]]; then
  echo "오류: UUID를 가져오지 못했습니다." >&2
  exit 1
fi

echo "== /etc/fstab 백업 및 항목 추가 (UUID=$UUID) =="
cp /etc/fstab /etc/fstab.bak.$(date +%Y%m%d%H%M%S)
if ! grep -q "$UUID" /etc/fstab; then
  echo "UUID=$UUID  $MOUNT_POINT  xfs  defaults  0  2" >> /etc/fstab
fi

echo "== mount -a 로 fstab 반영 =="
mount -a

echo "== 결과 확인 =="
df -h "$MOUNT_POINT"
findmnt "$MOUNT_POINT"

echo "완료: $DEVICE -> $MOUNT_POINT (UUID=$UUID)"
