#!/bin/bash
# MySQL 전체 백업 — Ceph 마이그레이션을 위해 /data를 비우기 전 안전 백업
# chan08(source)에서 실행. chan09(replica)는 복제 중지 후 폐기 예정이라 별도 백업 불필요.
#
# 사용법: sudo ./05-backup-mysql.sh

set -euo pipefail

BACKUP_DIR="/home/mysql-backup"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="${BACKUP_DIR}/all-databases-${STAMP}.sql.gz"

mkdir -p "$BACKUP_DIR"

echo "== mysqldump 실행 =="
mysqldump --all-databases --single-transaction --routines --triggers --events | gzip > "$OUT"

echo "== 무결성 확인 =="
gzip -t "$OUT" && echo "gzip 무결성 OK"
ls -lh "$OUT"

echo "완료: $OUT"
