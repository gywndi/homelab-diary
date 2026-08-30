#!/bin/bash
# NAS를 백업 타깃으로 이 노드에 직접 마운트한다 (k8s와 무관 — 호스트 레벨).
# chan08(etcd/MySQL 백업이 실제로 생성되는 노드)에서 실행.
#
# 이 스크립트가 만드는 k8s/ 하위 구조를 02-deploy-nfs-csi.sh(k8s RWX 스토리지)도
# 같이 쓴다 — 반드시 이 스크립트를 먼저 실행할 것.
#
# 사용법: sudo ./01-mount-nas-backup.sh

set -euo pipefail

MOUNT_POINT="/mnt/nas-backup"

echo "== NFS 클라이언트 설치 =="
apt-get update -y
apt-get install -y nfs-common

echo "== 마운트 =="
mkdir -p "$MOUNT_POINT"
# nfsvers=4/4.1은 이 NAS+드라이버 조합에서 "Protocol not supported"로 거부됐다.
# nfsvers=3 + nolock(=NFSv3 파일 잠금 데몬 rpc.statd 없이도 되게)이 실제로 동작하는 조합이다.
mount -t nfs -o vers=3,nolock nas.home:/volume1/nas "$MOUNT_POINT"

echo "== 재부팅해도 유지되도록 fstab 등록 =="
if ! grep -q nas-backup /etc/fstab; then
  echo "nas.home:/volume1/nas ${MOUNT_POINT} nfs vers=3,nolock,_netdev 0 0" >> /etc/fstab
fi

echo "== k8s 전용 하위 구조 준비 =="
# 이 NAS 공유(volume1/nas)에는 이미 다른 개인 데이터도 같이 있다 — k8s 관련은
# 전부 k8s/ 하위로만 한정해서 섞이지 않게 한다.
#   k8s/backups/etcd-backup, mysql-backup : 오프노드 백업 사본
#   k8s/rwx-pvs                           : k8s CSI가 자동 생성하는 RWX PV들
#   k8s/docker-images                     : (예약) 추후 이미지 레지스트리/캐시용
mkdir -p "${MOUNT_POINT}/k8s/backups/etcd-backup" \
         "${MOUNT_POINT}/k8s/backups/mysql-backup" \
         "${MOUNT_POINT}/k8s/rwx-pvs" \
         "${MOUNT_POINT}/k8s/docker-images"
chown -R "${SUDO_USER:-$(whoami)}:${SUDO_USER:-$(whoami)}" "${MOUNT_POINT}/k8s"

echo "완료: ${MOUNT_POINT}에 마운트됨."
df -h "$MOUNT_POINT"
