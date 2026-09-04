#!/bin/bash
# Vault 최초 초기화(init) + 3개 파드 전부 unseal.
# 테스트/학습용 편의 스크립트다 — 실제 운영이라면 unseal key 5개를 서로 다른
# 사람에게 하나씩 나눠주고 한 파일에 다 같이 저장하지 않는다(Shamir 분산의
# 의미 자체가 사라짐). 여기서는 재현 편의를 위해 로컬 파일에 저장한다.
#
# 사전 조건: 01-deploy-vault.sh로 vault-0만 떠 있는 상태(미초기화)
# 사용법: ./02-init-unseal.sh <키 저장할 파일 경로>
#   예: ./02-init-unseal.sh /tmp/vault-init.json

set -euo pipefail

KEYFILE="${1:-}"
if [[ -z "$KEYFILE" ]]; then
  echo "사용법: $0 <키 저장할 파일 경로>" >&2
  exit 1
fi

echo "== vault-0 초기화 (5 shares, threshold 3) =="
kubectl -n vault exec vault-0 -- vault operator init -key-shares=5 -key-threshold=3 -format=json > "$KEYFILE"
chmod 600 "$KEYFILE"

KEY1=$(python3 -c "import json,sys; print(json.load(open('$KEYFILE'))['unseal_keys_b64'][0])")
KEY2=$(python3 -c "import json,sys; print(json.load(open('$KEYFILE'))['unseal_keys_b64'][1])")
KEY3=$(python3 -c "import json,sys; print(json.load(open('$KEYFILE'))['unseal_keys_b64'][2])")

echo "== vault-0 unseal =="
kubectl -n vault exec vault-0 -- vault operator unseal "$KEY1" > /dev/null
kubectl -n vault exec vault-0 -- vault operator unseal "$KEY2" > /dev/null
kubectl -n vault exec vault-0 -- vault operator unseal "$KEY3" > /dev/null

echo "== vault-1이 뜰 때까지 대기 (vault-0이 Ready가 돼야 StatefulSet이 다음 파드를 만듦) =="
kubectl -n vault wait --for=condition=Ready pod/vault-0 --timeout=60s
until kubectl -n vault get pod vault-1 >/dev/null 2>&1; do sleep 3; done
sleep 10

echo "== vault-1 unseal (retry_join으로 이미 raft 클러스터를 인식한 상태) =="
kubectl -n vault exec vault-1 -- vault operator unseal "$KEY1" > /dev/null
kubectl -n vault exec vault-1 -- vault operator unseal "$KEY2" > /dev/null
kubectl -n vault exec vault-1 -- vault operator unseal "$KEY3" > /dev/null

echo "== vault-2가 뜰 때까지 대기 =="
kubectl -n vault wait --for=condition=Ready pod/vault-1 --timeout=60s
until kubectl -n vault get pod vault-2 >/dev/null 2>&1; do sleep 3; done
sleep 10

echo "== vault-2 unseal =="
kubectl -n vault exec vault-2 -- vault operator unseal "$KEY1" > /dev/null
kubectl -n vault exec vault-2 -- vault operator unseal "$KEY2" > /dev/null
kubectl -n vault exec vault-2 -- vault operator unseal "$KEY3" > /dev/null

echo "== 확인 =="
kubectl -n vault get pods
ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('$KEYFILE'))['root_token'])")
kubectl -n vault exec vault-0 -- env VAULT_TOKEN="$ROOT_TOKEN" vault operator raft list-peers

echo "완료: 3노드 전부 unseal됨. root token/unseal key는 ${KEYFILE} 참고."
