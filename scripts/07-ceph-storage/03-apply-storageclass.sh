#!/bin/bash
# RBD 풀 + StorageClass 생성
#
# 사용법: ./03-apply-storageclass.sh

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

kubectl apply -f "${DIR}/03-storageclass.yaml"

echo "== 확인 =="
kubectl -n rook-ceph get cephblockpool rbd-pool
kubectl get storageclass rook-ceph-block
