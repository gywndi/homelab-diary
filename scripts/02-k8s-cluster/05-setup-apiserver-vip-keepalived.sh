#!/bin/bash
# API 서버 앞단에 keepalived VIP를 구성한다 (컨트롤플레인 노드 전용)
#
# 04-init-control-plane.sh로 이 노드에 apiserver가 이미 떠 있는 상태에서 실행한다.
# 헬스체크가 로컬 apiserver(127.0.0.1:6443/livez)를 직접 찌르기 때문에 apiserver가
# 없으면 VIP가 뜨자마자 곧바로 내려간다 — 그래서 반드시 kubeadm init "이후"에 실행한다.
#
# 최초 노드(chan08)는 STATE=MASTER로 실행해서 VIP를 그 자리에서 바로 올린다. 이렇게
# 만들어둔 VIP를 04번에서 controlPlaneEndpoint로 이미 지정해뒀기 때문에, 나중에
# 컨트롤플레인을 추가할 때(kubeadm join --control-plane) 인증서를 재발급하거나
# 클러스터 설정을 뜯어고칠 필요가 없다 — 자세한 사정은 lessons/02-k8s-cluster.md의
# "알려진 이슈: 고정 IP로 시작하면 나중에 힘들다" 참고.
#
# 컨트롤플레인을 추가할 때마다(예: lessons/06-llm-gpu-node.md) 새 노드에서 이
# 스크립트를 STATE=BACKUP, 더 낮은 PRIORITY로 다시 실행해서 같은 VIP를 나눠 갖게 한다.
#
# 사용법: sudo ./05-setup-apiserver-vip-keepalived.sh <VIP> <인터페이스> <MASTER|BACKUP> <우선순위> <VRRP 인증암호>
#   예(최초 노드): ./05-setup-apiserver-vip-keepalived.sh 10.5.5.3 enp1s0 MASTER 150 <인증암호>
#   예(추가 노드): ./05-setup-apiserver-vip-keepalived.sh 10.5.5.3 enp1s0 BACKUP 140 <인증암호>
# 주의: 같은 VIP를 나눠 가질 노드들끼리는 <VRRP 인증암호>가 전부 동일해야 한다
#   (처음 실행할 때 openssl rand -hex 4 등으로 생성해서 안전하게 기록해두고 재사용).

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

VIP="${1:-}"
IFACE="${2:-}"
STATE="${3:-}"
PRIORITY="${4:-}"
AUTH_PASS="${5:-}"

if [[ -z "$VIP" || -z "$IFACE" || -z "$STATE" || -z "$PRIORITY" || -z "$AUTH_PASS" ]]; then
  echo "사용법: $0 <VIP> <인터페이스> <MASTER|BACKUP> <우선순위> <VRRP 인증암호>" >&2
  exit 1
fi

if ! command -v keepalived >/dev/null; then
  apt-get update -y
  apt-get install -y keepalived
fi

echo "== apiserver 헬스체크 스크립트 =="
cat > /usr/local/bin/chk_k8s_apiserver.sh <<'EOF'
#!/bin/bash
# 이 노드의 로컬 apiserver가 응답하는 동안에만 VIP를 들 자격이 있다고 본다.
curl -sk --max-time 2 -o /dev/null -w '%{http_code}' https://127.0.0.1:6443/livez | grep -q 200
EOF
chmod +x /usr/local/bin/chk_k8s_apiserver.sh

echo "== keepalived.conf에 VI_K8S_APISERVER 인스턴스 추가 (virtual_router_id=52) =="
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
ip -4 addr show "$IFACE" | grep "$VIP" || echo "(이 노드가 지금 VIP를 들고 있지 않음 - apiserver가 아직 없으면 정상)"

echo "완료: ${IFACE}에 VI_K8S_APISERVER(state=${STATE}, 우선순위=${PRIORITY}) 추가"
