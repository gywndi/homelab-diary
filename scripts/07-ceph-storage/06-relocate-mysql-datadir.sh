#!/bin/bash
# MySQL datadir을 /data(추후 Ceph OSD로 전환)에서 /home(nvme, OS 디스크)으로 영구 이전.
# chan08(source)에서 실행. /data 위치에서 다시 띄우지 않고 /home에서 바로 기동해서,
# /data 디스크를 이후 Ceph 구축 완료까지 기다리지 않고 바로 비울 수 있게 한다.
# (최종적으로는 여기서 다시 k8s StatefulSet(RBD PVC)으로 한 번 더 옮긴다.)
#
# 원본 /data/mysql은 삭제하지 않고 남겨둔다 — /data 디스크를 wipe하는 시점에 자연히 같이 없어짐.
#
# 사용법: sudo ./06-relocate-mysql-datadir.sh

set -euo pipefail

SRC="/data/mysql"
DST="/home/mysql"
APPARMOR_LOCAL="/etc/apparmor.d/local/usr.sbin.mysqld"

echo "== AppArmor: 새 경로 허용 추가 =="
if ! grep -qF "${DST}/ r," "$APPARMOR_LOCAL" 2>/dev/null; then
  cat >> "$APPARMOR_LOCAL" <<EOF
${DST}/ r,
${DST}/** rwk,
EOF
fi
apparmor_parser -r /etc/apparmor.d/usr.sbin.mysqld

echo "== mysqld 중지 =="
systemctl stop mysql

echo "== 물리 복사 (rsync -a로 소유권/권한 보존) =="
mkdir -p "$DST"
rsync -a "${SRC}/" "${DST}/"

echo "== datadir 설정 변경 =="
sed -i "s|^datadir\s*=.*|datadir = ${DST}|" /etc/mysql/mysql.conf.d/zz-datadir.cnf

echo "== mysqld 재기동 =="
systemctl start mysql
sleep 3
systemctl status mysql --no-pager

echo "== 확인 =="
mysql -e "SELECT @@datadir;"
mysql -e "SHOW DATABASES;"

echo "완료: MySQL datadir을 ${DST}로 이전 (원본 ${SRC}는 아직 보존됨)"
