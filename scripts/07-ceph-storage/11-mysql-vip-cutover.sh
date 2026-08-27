#!/bin/bash
# 기존 MySQL VIP를 keepalived에서 MetalLB(k8s Service)로 이관한다.
# 실행 전 10-mysql-deploy.yaml의 파드가 정상 기동 및 데이터 확인이 끝나 있어야 한다.
# keepalived를 내리는 순간부터 MetalLB가 VIP를 넘겨받을 때까지 짧은 창이 있다.
#
# 사용법: ./11-mysql-vip-cutover.sh <VIP> <keepalived-host1> [<keepalived-host2> ...]
#   예: ./11-mysql-vip-cutover.sh 10.5.5.4 10.5.5.8 10.5.5.9

set -euo pipefail

VIP="${1:-}"
shift || true
HOSTS=("$@")
if [[ -z "$VIP" || ${#HOSTS[@]} -eq 0 ]]; then
  echo "사용법: $0 <VIP> <keepalived-host1> [<keepalived-host2> ...]" >&2
  exit 1
fi

for h in "${HOSTS[@]}"; do
  echo "== $h: keepalived 중지 =="
  ssh "$h" 'sudo systemctl stop keepalived'
done

echo "== VIP 회수 확인 =="
ssh "${HOSTS[0]}" "ip addr show | grep \"$VIP\" && echo 'VIP 여전히 존재 - 확인 필요' || echo 'VIP 회수됨'"

cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: mysql-pool
  namespace: metallb-system
spec:
  addresses:
  - ${VIP}/32
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: mysql-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - mysql-pool
EOF

echo "== mysql Service를 LoadBalancer로 노출 =="
kubectl -n mysql patch svc mysql -p '{"spec":{"type":"LoadBalancer"}}'
sleep 3
kubectl -n mysql get svc mysql

echo "완료: VIP ${VIP} 컷오버. 연결 확인 후 keepalived/native mysql은 systemctl disable로 자동시작만 막아두고,"
echo "데이터/설정은 안정성 확인 기간 동안 보존할 것을 권장."
