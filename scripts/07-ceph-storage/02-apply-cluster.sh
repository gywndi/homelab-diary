#!/bin/bash
# CephCluster 생성 + 헬스 확인. mon 3개 + osd 3개가 다 뜨는 데 수 분 걸릴 수 있다.
#
# 사용법: ./02-apply-cluster.sh

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOK_VERSION="v1.20.6"

kubectl apply -f "${DIR}/02-cluster.yaml"

# kubectl wait는 매칭되는 리소스가 아직 하나도 없으면 기다리지 않고 바로 에러를 낸다
# (버전 감지 job -> mon 파드 생성까지 시간이 걸림) — 파드가 생기는 것부터 폴링한다.
wait_for_pods() {
  local label="$1"
  echo "== ${label} 파드 생성 대기 =="
  until [ -n "$(kubectl -n rook-ceph get pod -l "${label}" --no-headers 2>/dev/null)" ]; do
    sleep 10
  done
  echo "== ${label} Ready 대기 =="
  kubectl -n rook-ceph wait --for=condition=Ready pod -l "${label}" --timeout=600s
}

wait_for_pods "app=rook-ceph-mon"
wait_for_pods "app=rook-ceph-osd"

echo "== toolbox 설치 (ceph 명령 실행용) =="
kubectl apply -f "https://raw.githubusercontent.com/rook/rook/${ROOK_VERSION}/deploy/examples/toolbox.yaml"
kubectl -n rook-ceph rollout status deployment/rook-ceph-tools --timeout=120s

echo "== 클러스터 상태 확인 =="
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd tree
