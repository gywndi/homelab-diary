#!/bin/bash
# my.cnf 튜닝: buffer pool 2G, server-id, binlog/GTID
#
# 사용법: sudo ./02-tune.sh <server-id>
#   chan08: sudo ./02-tune.sh 1
#   chan09: sudo ./02-tune.sh 101

set -euo pipefail

SERVER_ID="${1:-}"
if [[ -z "$SERVER_ID" ]]; then
  echo "사용법: $0 <server-id>" >&2
  exit 1
fi

cat > /etc/mysql/mysql.conf.d/zz-stage1-tuning.cnf <<EOF
[mysqld]
innodb_buffer_pool_size = 2G
server-id = ${SERVER_ID}
log_bin = /data/mysql/mysql-bin
gtid_mode = ON
enforce_gtid_consistency = ON
binlog_format = ROW
bind-address = 0.0.0.0
EOF

systemctl restart mysql

echo "== 확인 =="
mysql -e "SHOW VARIABLES WHERE Variable_name IN ('innodb_buffer_pool_size','server_id','gtid_mode','binlog_format');"

echo "완료: my.cnf 튜닝 (server-id=$SERVER_ID)"
