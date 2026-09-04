#!/bin/bash
# Vault의 Kubernetes 인증 방식 활성화 — 파드가 자기 자신의 ServiceAccount
# 토큰으로 Vault에 로그인할 수 있게 한다. 정적 Vault 토큰을 앱 설정 파일에
# 박아 넣을 필요가 없어진다.
#
# 사전 조건: 03/04번 스크립트로 최소 하나의 secrets engine이 구성돼 있을 것
#            (이 스크립트는 예시로 demo-readonly 정책에 KV/DB 경로를 넣는다)
# 사용법: ./05-configure-k8s-auth.sh <root token>
#   예: ./05-configure-k8s-auth.sh hvs.xxxx

set -euo pipefail

VAULT_TOKEN="${1:-}"
if [[ -z "$VAULT_TOKEN" ]]; then
  echo "사용법: $0 <root token>" >&2
  exit 1
fi

echo "== Vault가 k8s TokenReview API를 호출할 수 있도록 RBAC 위임 =="
kubectl create clusterrolebinding vault-auth-delegator \
  --clusterrole=system:auth-delegator \
  --serviceaccount=vault:default \
  --dry-run=client -o yaml | kubectl apply -f -

echo "== kubernetes 인증 방식 활성화 + 설정 (vault-0 자신의 SA 토큰/CA로 같은 클러스터를 가리킴) =="
kubectl -n vault exec vault-0 -- env VAULT_TOKEN="$VAULT_TOKEN" sh -c '
vault auth enable kubernetes 2>/dev/null || true
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443" \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  token_reviewer_jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token
'

echo "== 정책 등록: secret/demo/app + database/creds/readonly 읽기만 =="
kubectl -n vault exec vault-0 -- env VAULT_TOKEN="$VAULT_TOKEN" sh -c '
vault policy write demo-readonly - <<EOF
path "secret/data/demo/app" {
  capabilities = ["read"]
}
path "database/creds/readonly" {
  capabilities = ["read"]
}
EOF
'

echo "== 역할 등록: default 네임스페이스의 demo-app ServiceAccount만 이 정책을 받게 =="
kubectl -n vault exec vault-0 -- env VAULT_TOKEN="$VAULT_TOKEN" vault write auth/kubernetes/role/demo-app \
  bound_service_account_names=demo-app \
  bound_service_account_namespaces=default \
  policies=demo-readonly \
  ttl=1h

echo "완료: default 네임스페이스에 demo-app ServiceAccount를 가진 파드는"
echo "  vault write auth/kubernetes/login role=demo-app jwt=@/var/run/secrets/kubernetes.io/serviceaccount/token"
echo "로 로그인해 demo-readonly 정책 범위의 시크릿만 읽을 수 있다."
