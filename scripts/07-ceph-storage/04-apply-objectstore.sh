#!/bin/bash
# CephObjectStore(RGW) 생성 + MetalLB로 S3 엔드포인트 VIP 노출
#
# VIP는 internal/ip-inventory.md에서 미사용으로 확인된 주소를 사용할 것 (이 저장소에선 비공개 문서)
#
# 사용법: ./04-apply-objectstore.sh <VIP>
#   예: ./04-apply-objectstore.sh 10.5.5.6

set -euo pipefail

VIP="${1:-}"
if [[ -z "$VIP" ]]; then
  echo "사용법: $0 <VIP>" >&2
  exit 1
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

kubectl apply -f "${DIR}/04-objectstore.yaml"

echo "== RGW 기동 대기 =="
kubectl -n rook-ceph wait --for=condition=Ready pod -l app=rook-ceph-rgw --timeout=180s

cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: rgw-pool
  namespace: metallb-system
spec:
  addresses:
  - ${VIP}/32
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: rgw-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - rgw-pool
EOF

echo "== RGW 서비스를 LoadBalancer로 노출 =="
# 정확한 서비스 이름은 rook-ceph-rgw-<store 이름> 규칙을 따름 — 아래로 실제 이름 확인 후 진행
kubectl -n rook-ceph get svc -l app=rook-ceph-rgw
kubectl -n rook-ceph patch svc rook-ceph-rgw-starrocks-store -p '{"spec":{"type":"LoadBalancer"}}'

echo "== 확인 =="
kubectl -n rook-ceph get svc rook-ceph-rgw-starrocks-store
