#!/bin/bash
# 기존 Ceph OSD 전용 디스크를 "고정 크기 Ceph 파티션 + XFS 파티션"으로 재분할한다.
# StarRocks shared-nothing(BE) 테스트용 로컬 스토리지를 확보하기 위한 작업.
#
# 중요: BlueStore는 원본 디스크 크기 기준으로 중복 레이블을 여러 위치(예: 1GB/10GB/107GB
# 지점)에 저장해둔다. 파티션을 줄인 뒤 앞부분 일부만 zero화하면 이 레이블들이 남아있어서
# Rook이 "새 OSD 생성"이 아니라 "기존 OSD expand"로 오판해 계속 크래시한다
# (ceph-bluestore-tool show-label로 실제 레이블 위치를 확인할 수 있다).
# 반드시 새 파티션 앞부분을 넉넉히(최소 110GB) zero화할 것.
#
# 사전 조건: 대상 OSD가 이미 ceph osd out → purge로 Ceph에서 완전히 제거되어 있어야 함
#            (순차 진행 시 노드 하나씩: out → PG remapping이 active+clean으로 안정화될 때까지
#             대기 → deployment 삭제 + purge → 이 스크립트 → operator 재시작으로 재프로비저닝)
#
# 사용법: 대상 노드에서 실행
#   ./12-resplit-osd-disk.sh <디바이스> <ceph파티션크기> <마운트경로>
#   예 (sda 전용 디스크, msdos): ./12-resplit-osd-disk.sh /dev/sda 300GB /mnt/local-data
#
# llm001처럼 OS와 같은 GPT 디스크를 공유하는 경우, 이 스크립트를 쓰지 말고 대상 파티션만
# `parted rm <번호>` 후 동일한 시작 오프셋으로 재생성하는 방식을 수동으로 적용할 것
# (OS 파티션을 건드리지 않도록 각별히 주의).

set -euo pipefail

DEVICE="${1:-}"
CEPH_SIZE="${2:-}"
MOUNT_PATH="${3:-}"
ZERO_SIZE_MB=112640  # 110GiB — BlueStore 중복 레이블 전부를 커버하기 위한 여유값

if [[ -z "$DEVICE" || -z "$CEPH_SIZE" || -z "$MOUNT_PATH" ]]; then
  echo "사용법: $0 <디바이스, 예: /dev/sda> <Ceph 파티션 크기, 예: 300GB> <XFS 마운트 경로>" >&2
  exit 1
fi

echo "== 사용 프로세스 확인 =="
sudo fuser -vm "$DEVICE" 2>&1 || echo "(사용 중인 프로세스 없음)"

echo "== 기존 시그니처 정리 =="
sudo wipefs -a "${DEVICE}1" 2>&1 || true
sudo wipefs -a "$DEVICE"

echo "== 파티션 재생성: p1=${CEPH_SIZE}(Ceph), p2=나머지(XFS) =="
sudo parted -s "$DEVICE" mklabel msdos
sudo parted -s "$DEVICE" mkpart primary 1MiB "$CEPH_SIZE"
sudo parted -s "$DEVICE" mkpart primary "$CEPH_SIZE" 100%
sudo partprobe "$DEVICE"
sleep 2
lsblk "$DEVICE"

CEPH_PART="${DEVICE}1"
XFS_PART="${DEVICE}2"

echo "== ${CEPH_PART} 앞 110GB 제로화 (BlueStore 중복 레이블 완전 제거) =="
sudo dd if=/dev/zero of="$CEPH_PART" bs=1M count="$ZERO_SIZE_MB" status=progress

echo "== ${XFS_PART}를 XFS로 포맷 =="
sudo mkfs.xfs -f "$XFS_PART"
sudo mkdir -p "$MOUNT_PATH"
sudo mount "$XFS_PART" "$MOUNT_PATH"
UUID=$(sudo blkid -s UUID -o value "$XFS_PART")
echo "UUID=${UUID} ${MOUNT_PATH} xfs defaults 0 2" | sudo tee -a /etc/fstab
df -h "$MOUNT_PATH"

echo "완료: ${CEPH_PART}는 Ceph 재프로비저닝 대상(다음 단계: operator 재시작, 필요 시 osd-prepare Job 강제 삭제),"
echo "${XFS_PART}는 ${MOUNT_PATH}에 마운트됨"
