#!/bin/bash
# 복제 소스(chan08) 설정: 복제 계정 생성 + semi-sync source 플러그인
#
# 사용법: sudo ./04-source-setup.sh
# 사전 조건: 03-generate-secrets.sh 로 /root/.mysql_repl_password 배포되어 있어야 함

set -euo pipefail

REPL_PASS_FILE="/root/.mysql_repl_password"
if [[ ! -f "$REPL_PASS_FILE" ]]; then
  echo "오류: $REPL_PASS_FILE 없음. 03-generate-secrets.sh를 먼저 실행하세요." >&2
  exit 1
fi
REPL_PASS=$(cat "$REPL_PASS_FILE")

mysql <<SQL
CREATE USER IF NOT EXISTS 'replicator'@'10.5.5.%' IDENTIFIED BY '${REPL_PASS}';
GRANT REPLICATION SLAVE ON *.* TO 'replicator'@'10.5.5.%';
FLUSH PRIVILEGES;
SQL

echo "== semi-sync source 플러그인 설치 =="
mysql -e "INSTALL PLUGIN rpl_semi_sync_source SONAME 'semisync_source.so';" || true
mysql -e "SET GLOBAL rpl_semi_sync_source_enabled = 1;"
mysql -e "SET PERSIST rpl_semi_sync_source_enabled = 1;"

echo "== 확인 =="
mysql -e "SHOW PLUGINS;" | grep -i semi_sync
mysql -e "SHOW VARIABLES LIKE 'rpl_semi_sync_source_enabled';"
mysql -e "SHOW MASTER STATUS\G" 2>/dev/null || mysql -e "SHOW BINARY LOG STATUS\G"

echo "완료: 복제 소스(chan08) 설정"
