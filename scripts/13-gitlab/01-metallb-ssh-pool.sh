#!/bin/bash
# git over SSH 전용 VIP(10.5.5.55) 풀을 MetalLB에 등록한다.
# ingress-nginx는 HTTP만 다루므로 SSH(22번)는 별도 LoadBalancer VIP로 노출해야 한다.
# 10.5.5.52~54는 StarRocks VM이 쓰고 있어 피했다.
#
# 사용법: ./01-metallb-ssh-pool.sh

set -euo pipefail

cat <<'EOF' | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: gitlab-pool
  namespace: metallb-system
spec:
  addresses:
    - 10.5.5.55/32
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: gitlab-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - gitlab-pool
EOF
