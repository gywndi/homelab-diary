#!/bin/bash
# keepalived 설치 및 MySQL VIP 페일오버 설정
#
# 사용법: sudo ./06-keepalived.sh <MASTER|BACKUP> <priority>
#   chan08: sudo ./06-keepalived.sh MASTER 150
#   chan09: sudo ./06-keepalived.sh BACKUP 100

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

STATE="${1:-}"
PRIORITY="${2:-}"
VIP="10.5.5.210"
VRRP_PASS_FILE="/root/.keepalived_vrrp_pass"

if [[ -z "$STATE" || -z "$PRIORITY" ]]; then
  echo "사용법: $0 <MASTER|BACKUP> <priority>" >&2
  exit 1
fi
if [[ ! -f "$VRRP_PASS_FILE" ]]; then
  echo "오류: $VRRP_PASS_FILE 없음. 03-generate-secrets.sh를 먼저 실행하세요." >&2
  exit 1
fi
VRRP_PASS=$(cat "$VRRP_PASS_FILE")

IFACE=$(ip -o -4 addr show | awk '$4 ~ /^10\.5\.5\./ {print $2; exit}')
if [[ -z "$IFACE" ]]; then
  echo "오류: 10.5.5.0/24 인터페이스를 찾지 못했습니다." >&2
  exit 1
fi

echo "== keepalived 설치 =="
apt-get update -y
apt-get install -y keepalived

echo "== mysqld 헬스체크 스크립트 =="
cat > /usr/local/bin/chk_mysql.sh <<'EOF'
#!/bin/bash
mysqladmin ping -h 127.0.0.1 --silent
EOF
chmod +x /usr/local/bin/chk_mysql.sh

echo "== keepalived.conf 작성 (interface=$IFACE) =="
cat > /etc/keepalived/keepalived.conf <<EOF
vrrp_script chk_mysql {
    script "/usr/local/bin/chk_mysql.sh"
    interval 2
    fall 3
    rise 2
}

vrrp_instance VI_MYSQL {
    state ${STATE}
    interface ${IFACE}
    virtual_router_id 51
    priority ${PRIORITY}
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass ${VRRP_PASS}
    }
    virtual_ipaddress {
        ${VIP}/24
    }
    track_script {
        chk_mysql
    }
}
EOF

systemctl restart keepalived
systemctl enable keepalived

echo "== 확인 =="
sleep 2
systemctl is-active keepalived
ip -4 addr show "$IFACE" | grep -E "inet |$VIP" || true

echo "완료: keepalived 설정 (state=$STATE, priority=$PRIORITY, vip=$VIP)"
