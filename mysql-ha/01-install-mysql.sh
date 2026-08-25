#!/bin/bash
# MySQL 8.0 설치 + datadir을 /data/mysql로 이전
#
# 사용법: sudo ./01-install-mysql.sh (양쪽 노드 모두 실행)

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "== mysql-server 설치 =="
apt-get update -y
apt-get install -y mysql-server

echo "== mysql 정지 =="
systemctl stop mysql

echo "== 기존 datadir 백업 및 /data/mysql로 이전 =="
BACKUP_DIR="/var/lib/mysql.bak.$(date +%Y%m%d%H%M%S)"
mv /var/lib/mysql "$BACKUP_DIR"
mkdir -p /data/mysql
rsync -a "$BACKUP_DIR"/ /data/mysql/
chown -R mysql:mysql /data/mysql
chmod 750 /data/mysql

echo "== AppArmor 로컬 오버라이드 추가 =="
touch /etc/apparmor.d/local/usr.sbin.mysqld
if ! grep -q "^/data/mysql/" /etc/apparmor.d/local/usr.sbin.mysqld; then
  cat >> /etc/apparmor.d/local/usr.sbin.mysqld <<EOF
/data/mysql/ r,
/data/mysql/** rwk,
EOF
fi
systemctl restart apparmor

echo "== datadir 설정 (별도 conf.d 파일로, mysqld.cnf의 datadir 줄은 기본 주석 처리라 sed로 못 건드림) =="
cat > /etc/mysql/mysql.conf.d/zz-datadir.cnf <<EOF
[mysqld]
datadir = /data/mysql
EOF

echo "== mysql 시작 =="
systemctl reset-failed mysql || true
systemctl start mysql
systemctl enable mysql

echo "== 확인 =="
systemctl is-active mysql
mysql -e "SELECT @@datadir;"

echo "완료: MySQL 설치 및 datadir 이전 (백업: $BACKUP_DIR)"
