#!/bin/bash
# NAS(nas.home)를 k8s의 ReadWriteMany(RWX) 스토리지로 붙인다.
# NAS 쪽 NFS 서비스/공유 폴더는 이미 떠 있다는 전제(showmount -e nas.home로 확인).
# k8s가 쓸 데이터는 그 공유 폴더 전체가 아니라 k8s/rwx-pvs 하위 디렉터리로 한정한다
# (같은 공유에 개인 데이터가 섞여 있을 수 있어서 — lessons/10-nas-storage.md 참고).
# 이 하위 디렉터리는 01-mount-nas-backup.sh가 먼저 만들어둔다는 전제.
#
# 사용법: ./02-deploy-nfs-csi.sh (kubectl 접근 가능한 곳에서, 3노드 어디서든)

set -euo pipefail

CSI_VERSION="v4.13.4"

echo "== csi-driver-nfs 설치 (컨트롤러 + 노드 DaemonSet) =="
for f in rbac-csi-nfs.yaml csi-nfs-driverinfo.yaml csi-nfs-controller.yaml csi-nfs-node.yaml; do
  kubectl apply -f "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/${CSI_VERSION}/deploy/${CSI_VERSION}/${f}"
done

echo "== 기동 대기 =="
kubectl -n kube-system rollout status deployment/csi-nfs-controller --timeout=90s
kubectl -n kube-system rollout status daemonset/csi-nfs-node --timeout=90s

echo "== StorageClass 등록 =="
# nfsvers=4/4.1은 이 NAS+드라이버 조합에서 "Protocol not supported"로 거부됐다.
# nfsvers=3 + nolock(=NFSv3 파일 잠금 데몬 rpc.statd 없이도 되게)이 실제로 동작하는 조합이다.
cat <<'EOF' | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-nas
provisioner: nfs.csi.k8s.io
parameters:
  server: nas.home
  share: /volume1/nas/k8s/rwx-pvs
reclaimPolicy: Retain
volumeBindingMode: Immediate
mountOptions:
  - nfsvers=3
  - nolock
EOF

echo "완료: StorageClass nfs-nas 등록됨. PVC의 accessModes: ReadWriteMany로 사용."
