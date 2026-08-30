#!/bin/bash
# cert-manager 설치 (Let's Encrypt 인증서 자동 발급/갱신)
#
# 사용법: ./05-install-cert-manager.sh

set -euo pipefail

kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.20.2/cert-manager.yaml

echo "== 롤아웃 대기 =="
kubectl -n cert-manager wait --for=condition=Available deployment --all --timeout=120s

echo "== 확인 =="
kubectl -n cert-manager get pods -o wide
