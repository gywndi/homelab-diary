#!/bin/bash
# Rook-Ceph operator 설치 (CRD + 공통 리소스 + operator)
#
# 사전 조건: chan08/chan09/llm001 3노드 모두 /data 디스크를 wipefs로 raw 상태로 만들어둘 것
#            (internal/specs/implementation-plan.md "Stage 3.5" 참고 — 이 저장소에선 비공개)
#
# 사용법: kubectl 접근 가능한 컨트롤플레인(chan08 등)에서 실행
#   ./01-install-rook-operator.sh

set -euo pipefail

ROOK_VERSION="v1.20.6"
BASE="https://raw.githubusercontent.com/rook/rook/${ROOK_VERSION}/deploy/examples"

kubectl apply -f "${BASE}/crds.yaml"
kubectl apply -f "${BASE}/common.yaml"
kubectl apply -f "${BASE}/operator.yaml"

echo "== operator 롤아웃 대기 =="
kubectl -n rook-ceph rollout status deployment/rook-ceph-operator --timeout=180s

echo "== 확인 =="
kubectl -n rook-ceph get pods
