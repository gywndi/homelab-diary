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

echo "== RGW 파드 생성 대기 =="
# kubectl wait는 매칭되는 리소스가 하나도 없으면 기다리지 않고 바로 에러를 낸다.
until [ -n "$(kubectl -n rook-ceph get pod -l app=rook-ceph-rgw --no-headers 2>/dev/null)" ]; do
  sleep 10
done
echo "== RGW Ready 대기 =="
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

echo "== RGW 전용 LoadBalancer Service 생성 =="
# Rook이 소유한 rook-ceph-rgw-starrocks-store Service를 직접 patch하면 안 된다 —
# CephObjectStore CRD의 gateway.service는 annotations/labels만 지원하고 type은 없어서,
# operator가 reconcile할 때마다 Service type이 ClusterIP로 계속 되돌아간다
# (MetalLB가 VIP를 할당해도 몇 초 뒤 Service가 리셋되며 사라짐).
# 대신 같은 파드 라벨을 셀렉터로 쓰는 별도 Service를 만들어 그것만 LoadBalancer로 둔다.
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: rgw-starrocks-store-lb
  namespace: rook-ceph
spec:
  type: LoadBalancer
  selector:
    app: rook-ceph-rgw
    rgw: starrocks-store
    rook_cluster: rook-ceph
    rook_object_store: starrocks-store
  ports:
    - name: http
      port: 7480
      targetPort: 7480
EOF

echo "== 확인 =="
kubectl -n rook-ceph get svc rgw-starrocks-store-lb
