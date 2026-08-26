#!/bin/bash
# etcd 스냅샷 백업.
#
# 컨트롤플레인이 chan08 하나뿐이라 etcd도 단일 장애점이다 — chan08이
# 완전히 죽으면 클러스터 상태(모든 리소스, Secret, 인증서 등)를 전부
# 잃을 수 있다. 주기적으로 스냅샷을 떠서 최소한 복구는 가능하게 한다.
# cron으로 주기 실행하는 걸 권장 (예: 매일 새벽).
#
# etcd 컨테이너 이미지가 워낙 최소 구성이라(tar/cat/rm도 없음) kubectl cp를
# 못 쓴다. 대신 etcd 파드의 hostPath 볼륨(/var/lib/etcd, 호스트와 그대로
# 매핑됨)에 스냅샷을 떠서 호스트 쪽에서 직접 꺼내는 방식을 쓴다.
#
# 사용법: ./07-etcd-backup.sh [보관 개수, 기본 7]
#   ./07-etcd-backup.sh
#   ./07-etcd-backup.sh 14

set -euo pipefail

KEEP="${1:-7}"
BACKUP_DIR="/data/etcd-backup"
TIMESTAMP="$(date +%Y%m%d%H%M%S)"
SNAPSHOT_NAME="etcd-snapshot-${TIMESTAMP}.db"
POD_TMP_PATH="/var/lib/etcd/etcd-backup-tmp.db"
HOST_TMP_PATH="/var/lib/etcd/etcd-backup-tmp.db"

sudo mkdir -p "$BACKUP_DIR"
sudo chown "$(whoami)" "$BACKUP_DIR"

echo "== etcd 파드 안에서 스냅샷 생성 (hostPath 볼륨에 바로 씀) =="
kubectl -n kube-system exec etcd-chan08 -- etcdctl snapshot save "$POD_TMP_PATH" \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key

echo "== 스냅샷 무결성 확인 =="
kubectl -n kube-system exec etcd-chan08 -- etcdutl snapshot status "$POD_TMP_PATH" --write-out=table

echo "== 호스트 쪽에서 직접 이동 (hostPath라 같은 파일) =="
sudo mv "$HOST_TMP_PATH" "${BACKUP_DIR}/${SNAPSHOT_NAME}"
sudo chown "$(whoami)" "${BACKUP_DIR}/${SNAPSHOT_NAME}"
chmod 600 "${BACKUP_DIR}/${SNAPSHOT_NAME}"

echo "== 오래된 백업 정리 (최근 ${KEEP}개만 유지) =="
ls -1t "${BACKUP_DIR}"/etcd-snapshot-*.db | tail -n +"$((KEEP + 1))" | xargs -r rm -v --

echo "== 현재 보관 중인 백업 =="
ls -lh "${BACKUP_DIR}"
