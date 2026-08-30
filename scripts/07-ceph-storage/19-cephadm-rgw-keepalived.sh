#!/bin/bash
# RGW 앞단에 keepalived VIP를 구성한다. RGW는 더 이상 k8s Service가 아니라
# MetalLB를 못 쓴다 — MySQL Stage 1/k8s API 서버 VIP와 같은 host-native VRRP
# 패턴(keepalived)을 재사용한다. VIP는 인프라 대역(`.20` 이하) — Ceph는 다른
# 서비스가 의존하는 핵심 인프라라 애플리케이션 VIP 대역과 구분한다.
#
# keepalived.conf에 이미 다른 vrrp_instance(k8s API 서버 등)가 있을 수 있어
# 파일 전체를 덮어쓰지 않고 VI_RGW 블록만 추가한다.
#
# 사용법: sudo ./19-cephadm-rgw-keepalived.sh <MASTER|BACKUP> <priority> <VIP, 예: 10.5.5.4> <VRRP 인증키, 8자 이하>
#   chan08: sudo ./19-cephadm-rgw-keepalived.sh MASTER 150 10.5.5.4 <같은 키>
#   chan09: sudo ./19-cephadm-rgw-keepalived.sh BACKUP 140 10.5.5.4 <같은 키>
#   llm001: sudo ./19-cephadm-rgw-keepalived.sh BACKUP 130 10.5.5.4 <같은 키>

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

STATE="${1:-}"
PRIORITY="${2:-}"
VIP="${3:-}"
VRRP_PASS="${4:-}"
VIRTUAL_ROUTER_ID=53   # 51=MySQL(폐기), 52=k8s API 서버와 겹치지 않게 53 사용

if [[ -z "$STATE" || -z "$PRIORITY" || -z "$VIP" || -z "$VRRP_PASS" ]]; then
  echo "사용법: $0 <MASTER|BACKUP> <priority> <VIP> <VRRP 인증키>" >&2
  exit 1
fi

IFACE=$(ip -o -4 addr show | awk '$4 ~ /^10\.5\.5\./ {print $2; exit}')

echo "== keepalived 설치(이미 있으면 스킵) =="
apt-get update -y
apt-get install -y keepalived

echo "== RGW 헬스체크 스크립트 =="
cat > /usr/local/bin/chk_rgw.sh <<'EOF'
#!/bin/bash
curl -sf -o /dev/null http://127.0.0.1:7480/
EOF
chmod +x /usr/local/bin/chk_rgw.sh

if grep -q "VI_RGW" /etc/keepalived/keepalived.conf 2>/dev/null; then
  echo "VI_RGW 블록이 이미 있음 — 건너뜀"
else
  echo "== keepalived.conf에 VI_RGW 블록 추가(interface=$IFACE) =="
  cat >> /etc/keepalived/keepalived.conf <<EOF

vrrp_script chk_rgw {
    script "/usr/local/bin/chk_rgw.sh"
    interval 2
    fall 3
    rise 2
}

vrrp_instance VI_RGW {
    state ${STATE}
    interface ${IFACE}
    virtual_router_id ${VIRTUAL_ROUTER_ID}
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
        chk_rgw
    }
}
EOF
fi

systemctl enable --now keepalived
systemctl restart keepalived
