#!/bin/bash
# 컨트롤플레인 API 서버 VIP용 keepalived 인스턴스를 추가
#
# 기존에 다른 용도(예: MySQL VIP)로 keepalived를 쓰고 있어도 상관없다 —
# virtual_router_id만 겹치지 않으면 같은 keepalived.conf에 vrrp_instance를
# 여러 개 둘 수 있다. 헬스체크는 로컬 apiserver의 /livez를 확인한다.
#
# 사용법: sudo ./04-setup-apiserver-vip-keepalived.sh <VIP> <인터페이스> <상태:MASTER|BACKUP> <우선순위>
#   예: ./04-setup-apiserver-vip-keepalived.sh 10.5.5.3 enp1s0 MASTER 150
#   예: ./04-setup-apiserver-vip-keepalived.sh 10.5.5.3 br0 BACKUP 130

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

VIP="${1:-}"
IFACE="${2:-}"
STATE="${3:-}"
PRIORITY="${4:-}"
AUTH_PASS="${5:-a7f21ce9}"

if [[ -z "$VIP" || -z "$IFACE" || -z "$STATE" || -z "$PRIORITY" ]]; then
  echo "사용법: $0 <VIP> <인터페이스> <MASTER|BACKUP> <우선순위> [인증암호]" >&2
  exit 1
fi

if ! command -v keepalived >/dev/null; then
  apt-get update -y
  apt-get install -y keepalived
fi

cat > /usr/local/bin/chk_k8s_apiserver.sh <<'EOF'
#!/bin/bash
curl -sk --max-time 2 -o /dev/null -w '%{http_code}' https://127.0.0.1:6443/livez | grep -q 200
EOF
chmod +x /usr/local/bin/chk_k8s_apiserver.sh

cat >> /etc/keepalived/keepalived.conf <<EOF

vrrp_script chk_k8s_apiserver {
    script "/usr/local/bin/chk_k8s_apiserver.sh"
    interval 2
    fall 3
    rise 2
}

vrrp_instance VI_K8S_APISERVER {
    state ${STATE}
    interface ${IFACE}
    virtual_router_id 52
    priority ${PRIORITY}
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass ${AUTH_PASS}
    }
    virtual_ipaddress {
        ${VIP}/24
    }
    track_script {
        chk_k8s_apiserver
    }
}
EOF

systemctl enable keepalived >/dev/null 2>&1 || true
systemctl restart keepalived

echo "== 확인 =="
sleep 3
systemctl is-active keepalived
ip -4 addr show "$IFACE" | grep "$VIP" || echo "(이 노드가 지금 VIP를 들고 있지 않음 - 정상일 수 있음)"

echo "완료: ${IFACE}에 VI_K8S_APISERVER(우선순위 ${PRIORITY}) 추가"
