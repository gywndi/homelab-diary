#!/bin/bash
# MetalLB에 VIP로 쓸 IP 대역을 등록 (IPAddressPool + L2Advertisement)
#
# 사용법: ./02-configure-metallb-pool.sh <VIP>
#   예: ./02-configure-metallb-pool.sh 10.5.5.50

set -euo pipefail

VIP="${1:-}"
if [[ -z "$VIP" ]]; then
  echo "사용법: $0 <VIP>" >&2
  exit 1
fi

cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: ingress-pool
  namespace: metallb-system
spec:
  addresses:
  - ${VIP}/32
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: ingress-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - ingress-pool
EOF

echo "== 확인 =="
kubectl -n metallb-system get ipaddresspool,l2advertisement
