#!/bin/bash
# MetalLB 설치 (bare-metal용 LoadBalancer 구현체)
#
# 사용법: sudo가 아니라 kubectl 접근 가능한 계정으로 컨트롤플레인에서 실행
#   ./01-install-metallb.sh

set -euo pipefail

kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.16.1/config/manifests/metallb-native.yaml

echo "== 롤아웃 대기 =="
kubectl -n metallb-system rollout status deployment/controller --timeout=120s
kubectl -n metallb-system rollout status daemonset/speaker --timeout=120s

echo "== 확인 =="
kubectl -n metallb-system get pods -o wide
