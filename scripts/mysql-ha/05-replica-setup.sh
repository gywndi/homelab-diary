#!/bin/bash
# 복제 레플리카(chan09) 설정: semi-sync replica 플러그인 + 복제 시작
#
# 사용법: sudo ./05-replica-setup.sh
# 사전 조건: 03-generate-secrets.sh 로 /root/.mysql_repl_password 배포, 04-source-setup.sh가 chan08에서 먼저 실행되어 있어야 함

set -euo pipefail

SOURCE_HOST="10.5.5.8"
REPL_PASS_FILE="/root/.mysql_repl_password"
if [[ ! -f "$REPL_PASS_FILE" ]]; then
  echo "오류: $REPL_PASS_FILE 없음. 03-generate-secrets.sh를 먼저 실행하세요." >&2
  exit 1
fi
REPL_PASS=$(cat "$REPL_PASS_FILE")

echo "== semi-sync replica 플러그인 설치 =="
mysql -e "INSTALL PLUGIN rpl_semi_sync_replica SONAME 'semisync_replica.so';" || true
mysql -e "SET GLOBAL rpl_semi_sync_replica_enabled = 1;"
mysql -e "SET PERSIST rpl_semi_sync_replica_enabled = 1;"

echo "== 복제 설정 =="
mysql <<SQL
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='${SOURCE_HOST}',
  SOURCE_USER='replicator',
  SOURCE_PASSWORD='${REPL_PASS}',
  SOURCE_AUTO_POSITION=1,
  GET_SOURCE_PUBLIC_KEY=1;
START REPLICA;
SQL

sleep 3

echo "== 확인 =="
mysql -e "SHOW REPLICA STATUS\G" | grep -E "Replica_IO_Running|Replica_SQL_Running|Last_IO_Error|Last_SQL_Error|Seconds_Behind_Source"

echo "완료: 복제 레플리카(chan09) 설정"
