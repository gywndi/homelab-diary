#!/bin/bash
# Vault를 사설 CA로 쓰는 TLS 발급 체계를 만든다(대안 구성).
# 현재 GitLab은 공인 인증서(Let's Encrypt)를 쓰므로 이 구성을 직접 사용하지 않는다.
# 사내 전용 이름(*.k8s.home)처럼 공인 인증서를 받을 수 없는 서비스용으로 남겨둔 것이다.
#
# 사용법: ./07-vault-pki-issuer.sh <Vault root token>

set -euo pipefail

VAULT_TOKEN="${1:?사용법: $0 <Vault root token>}"
V() { kubectl -n vault exec -i vault-0 -- env VAULT_TOKEN="$VAULT_TOKEN" vault "$@"; }

echo "== pki-home 마운트 + root CA(homelab-root-ca, 10년) =="
V secrets enable -path=pki-home pki
V secrets tune -max-lease-ttl=87600h pki-home
V write -field=certificate pki-home/root/generate/internal \
  common_name="homelab-root-ca" ttl=87600h > homelab-root-ca.pem

echo "== 발급 규칙: k8s.home 및 하위 도메인만, 최대 90일 (ingress CSR에는 CN이 없어 require_cn=false) =="
V write pki-home/roles/k8s-home \
  allowed_domains="k8s.home" \
  allow_subdomains=true \
  require_cn=false \
  max_ttl="2160h"

echo "== cert-manager가 쓸 정책/k8s 인증 역할 (서명 경로만 허용) =="
V policy write cert-manager-pki - <<'POLICY'
path "pki-home/sign/k8s-home" {
  capabilities = ["update"]
}
POLICY
V write auth/kubernetes/role/cert-manager \
  bound_service_account_names=vault-issuer \
  bound_service_account_namespaces=cert-manager \
  policies=cert-manager-pki \
  ttl=10m

echo "== cert-manager 쪽 ServiceAccount/권한/ClusterIssuer =="
cat <<'EOF' | kubectl apply -f -
# cert-manager → Vault(pki-home) 연동. Vault k8s 인증으로 로그인하므로 정적 토큰이 없다.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-issuer
  namespace: cert-manager
---
# cert-manager 컨트롤러가 vault-issuer SA의 토큰을 발급(TokenRequest)할 수 있게 허용
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: vault-issuer-token
  namespace: cert-manager
rules:
  - apiGroups: [""]
    resources: [serviceaccounts/token]
    resourceNames: [vault-issuer]
    verbs: [create]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: vault-issuer-token
  namespace: cert-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: vault-issuer-token
subjects:
  - kind: ServiceAccount
    name: cert-manager
    namespace: cert-manager
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: vault-home
spec:
  vault:
    server: http://vault.vault.svc:8200
    path: pki-home/sign/k8s-home
    auth:
      kubernetes:
        role: cert-manager
        mountPath: /v1/auth/kubernetes
        serviceAccountRef:
          name: vault-issuer
EOF
