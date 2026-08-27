#!/bin/bash
# /data 디스크를 Ceph OSD용 raw 상태로 전환 — umount 후 파일시스템 시그니처 제거
# 사전 조건: 이 디스크에 있던 데이터(MySQL/VM/기타)가 이미 다른 곳으로 이전/백업되어 있어야 함.
# 되돌릴 수 없는 작업이다.
#
# 사용법: sudo ./07-wipe-data-disk.sh

set -euo pipefail

MOUNT="/data"
DEV=$(findmnt -n -o SOURCE "$MOUNT")

echo "== 대상 디바이스: ${DEV} (마운트: ${MOUNT}) =="

echo "== umount =="
umount "$MOUNT"

echo "== wipefs =="
wipefs -a "$DEV"

echo "== fstab 정리 =="
sed -i "\|[[:space:]]${MOUNT}[[:space:]]|d" /etc/fstab

echo "== 확인 =="
lsblk "$DEV" 2>/dev/null || true
blkid "$DEV" || echo "(시그니처 없음 — 정상)"

echo "완료: ${DEV} raw 상태 전환"
