#!/bin/bash
# Vault PKI secrets engine — Vault를 자체 CA로 써서 짧은 수명의 TLS 인증서를
# 요청 시점에 발급한다. 기존 인프라(cert-manager 등)와 완전히 분리된 테스트용
# CA다 — 여기서 발급한 인증서를 실제로 어딘가에 연결하지 않는 한 다른
# 컴포넌트에 영향이 없다.
#
# 사전 조건: 02-init-unseal.sh 완료
# 사용법: ./04-configure-pki.sh <root token>
#   예: ./04-configure-pki.sh hvs.xxxx

set -euo pipefail

VAULT_TOKEN="${1:-}"
if [[ -z "$VAULT_TOKEN" ]]; then
  echo "사용법: $0 <root token>" >&2
  exit 1
fi

echo "== PKI 엔진 활성화 + 최대 TTL을 10년으로 (root CA 자체 수명용) =="
kubectl -n vault exec vault-0 -- env VAULT_TOKEN="$VAULT_TOKEN" vault secrets enable pki
kubectl -n vault exec vault-0 -- env VAULT_TOKEN="$VAULT_TOKEN" vault secrets tune -max-lease-ttl=87600h pki

echo "== root CA 생성 (10년) =="
kubectl -n vault exec vault-0 -- env VAULT_TOKEN="$VAULT_TOKEN" vault write -field=certificate pki/root/generate/internal \
  common_name="vault-test.internal" \
  ttl=87600h

echo "== 발급 규칙(role): vault-test.internal과 그 서브도메인만, 최대 TTL 1시간 =="
kubectl -n vault exec vault-0 -- env VAULT_TOKEN="$VAULT_TOKEN" vault write pki/roles/test-role \
  allowed_domains="vault-test.internal" \
  allow_subdomains=true \
  max_ttl="1h"

echo "완료: pki/issue/test-role 로 인증서 발급 가능"
echo "  vault write pki/issue/test-role common_name=<이름>.vault-test.internal ttl=1h"
