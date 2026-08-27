#!/bin/bash
# CephCluster 생성 + 헬스 확인. mon 3개 + osd 3개가 다 뜨는 데 수 분 걸릴 수 있다.
#
# 사용법: ./02-apply-cluster.sh

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOK_VERSION="v1.20.6"

kubectl apply -f "${DIR}/02-cluster.yaml"

echo "== mon 기동 대기 =="
kubectl -n rook-ceph wait --for=condition=Ready pod -l app=rook-ceph-mon --timeout=600s

echo "== osd 기동 대기 =="
kubectl -n rook-ceph wait --for=condition=Ready pod -l app=rook-ceph-osd --timeout=600s

echo "== toolbox 설치 (ceph 명령 실행용) =="
kubectl apply -f "https://raw.githubusercontent.com/rook/rook/${ROOK_VERSION}/deploy/examples/toolbox.yaml"
kubectl -n rook-ceph rollout status deployment/rook-ceph-tools --timeout=120s

echo "== 클러스터 상태 확인 =="
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd tree
