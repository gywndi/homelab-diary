#!/bin/bash
# Let's Encrypt ClusterIssuer 두 개 생성 (staging + production)
#
# staging은 브라우저가 신뢰하지 않는 테스트 발급자 — 실제 도메인/HTTP-01
# 경로가 제대로 뚫려 있는지 rate limit 걱정 없이 먼저 검증하는 용도.
# 검증되면 Ingress의 cert-manager.io/cluster-issuer 값만 letsencrypt-prod로
# 바꿔주면 같은 도메인으로 재발급된다.
#
# 사용법: ./06-create-clusterissuers.sh <이메일>
#   예: ./06-create-clusterissuers.sh admin@example.com

set -euo pipefail

EMAIL="${1:-}"
if [[ -z "$EMAIL" ]]; then
  echo "사용법: $0 <이메일>" >&2
  exit 1
fi

cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: ${EMAIL}
    privateKeySecretRef:
      name: letsencrypt-staging-account-key
    solvers:
    - http01:
        ingress:
          ingressClassName: nginx
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${EMAIL}
    privateKeySecretRef:
      name: letsencrypt-prod-account-key
    solvers:
    - http01:
        ingress:
          ingressClassName: nginx
EOF

echo "== 확인 (둘 다 READY=True 여야 함) =="
sleep 5
kubectl get clusterissuer
