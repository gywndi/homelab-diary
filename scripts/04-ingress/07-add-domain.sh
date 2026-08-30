#!/bin/bash
# 도메인 하나를 클러스터 밖 백엔드로 라우팅하는 Ingress를 추가한다.
#
# 백엔드가 클러스터 밖(다른 서버/이 서버가 아닌 물리 머신)에 있으므로
# 선택자 없는 Service + EndpointSlice로 외부 IP:포트를 등록한 뒤 Ingress를
# 붙인다. 처음엔 letsencrypt-staging으로 검증하고, 문제없으면
# `kubectl annotate ingress <이름> cert-manager.io/cluster-issuer=letsencrypt-prod --overwrite`로
# 프로덕션 인증서로 전환한다.
#
# 사용법: ./07-add-domain.sh <도메인> <백엔드IP> <백엔드포트> <issuer: staging|prod>
#   예: ./07-add-domain.sh app1.example.com 10.5.5.7 4200 staging

set -euo pipefail

DOMAIN="${1:-}"
BACKEND_IP="${2:-}"
BACKEND_PORT="${3:-}"
ISSUER="${4:-staging}"

if [[ -z "$DOMAIN" || -z "$BACKEND_IP" || -z "$BACKEND_PORT" ]]; then
  echo "사용법: $0 <도메인> <백엔드IP> <백엔드포트> <issuer: staging|prod>" >&2
  exit 1
fi

# 도메인의 점(.)을 하이픈으로 바꿔 리소스 이름으로 사용
NAME="$(echo "$DOMAIN" | tr '.' '-')"

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ext-${NAME}
spec:
  ports:
  - port: ${BACKEND_PORT}
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: ext-${NAME}
  labels:
    kubernetes.io/service-name: ext-${NAME}
addressType: IPv4
ports:
- port: ${BACKEND_PORT}
endpoints:
- addresses: ["${BACKEND_IP}"]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${NAME}
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-${ISSUER}
spec:
  ingressClassName: nginx
  tls:
  - hosts: [${DOMAIN}]
    secretName: ${NAME}-tls
  rules:
  - host: ${DOMAIN}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ext-${NAME}
            port:
              number: ${BACKEND_PORT}
EOF

echo "== 확인 =="
kubectl get ingress "$NAME"
kubectl get certificate "${NAME}-tls"
