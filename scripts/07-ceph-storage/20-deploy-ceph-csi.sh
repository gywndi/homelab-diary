#!/bin/bash
# k8s가 RBD(블록) 볼륨을 PVC로 쓸 수 있게 독립 ceph-csi(Rook 아님)를 배포한다.
# k8s는 이 외부 클러스터의 "소비자"일 뿐, 클러스터 생애주기는 전혀 관리하지 않는다.
#
# 사전 조건: 17-cephadm-rbd-pool.sh 완료, chan08에서 cephadm 접근 가능
# 사용법: chan08에서 실행
#   sudo ./20-deploy-ceph-csi.sh

set -euo pipefail

CEPH_CSI_VERSION="v3.17.1"
FSID=$(cephadm shell -- ceph fsid 2>&1 | tail -1)
MONITORS="10.5.5.8:6789, 10.5.5.9:6789, 10.5.5.10:6789"

echo "== 전용 cephx 유저(client.k8s, least-privilege) 생성 =="
cephadm shell -- ceph auth get-or-create client.k8s \
  mon 'profile rbd' \
  osd 'profile rbd pool=rbd-pool' \
  mgr 'profile rbd pool=rbd-pool'
K8S_KEY=$(cephadm shell -- ceph auth get-key client.k8s 2>&1 | tail -1)

echo "== ceph-csi 매니페스트 다운로드 =="
mkdir -p ~/ceph-csi-rbd && cd ~/ceph-csi-rbd
for f in csi-config-map.yaml csi-nodeplugin-rbac.yaml csi-provisioner-rbac.yaml csi-rbdplugin-provisioner.yaml csi-rbdplugin.yaml csidriver.yaml; do
  curl -s -o "$f" "https://raw.githubusercontent.com/ceph/ceph-csi/${CEPH_CSI_VERSION}/deploy/rbd/kubernetes/${f}"
done
sed -i "s/namespace: default/namespace: ceph-csi/g" *.yaml

echo "== 클러스터 설정(clusterID/monitors) 반영 =="
cat > csi-config-map.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ceph-csi-config
  namespace: ceph-csi
data:
  config.json: |-
    [
      {
        "clusterID": "${FSID}",
        "monitors": [$(echo "$MONITORS" | sed 's/\([0-9.]*:[0-9]*\)/"\1"/g')]
      }
    ]
EOF

echo "== 네임스페이스/Secret/보조 ConfigMap 생성 =="
kubectl create namespace ceph-csi --dry-run=client -o yaml | kubectl apply -f -
kubectl -n ceph-csi create secret generic csi-rbd-secret \
  --from-literal=userID=k8s \
  --from-literal=userKey="$K8S_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n ceph-csi create configmap ceph-csi-encryption-kms-config --from-literal=config.json='{}' --dry-run=client -o yaml | kubectl apply -f -
kubectl -n ceph-csi create configmap ceph-config \
  --from-literal=ceph.conf=$'[global]\n' \
  --from-literal=keyring='' \
  --dry-run=client -o yaml | kubectl apply -f -

echo "== CSI 드라이버/RBAC/provisioner/nodeplugin 적용 =="
kubectl apply -f csi-config-map.yaml
kubectl apply -f csidriver.yaml
kubectl apply -f csi-provisioner-rbac.yaml
kubectl apply -f csi-nodeplugin-rbac.yaml
kubectl apply -f csi-rbdplugin-provisioner.yaml
kubectl apply -f csi-rbdplugin.yaml

echo "== StorageClass 생성(krbd 기본 마운터) =="
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-csi-rbd
provisioner: rbd.csi.ceph.com
parameters:
  clusterID: ${FSID}
  pool: rbd-pool
  imageFeatures: layering
  csi.storage.k8s.io/provisioner-secret-name: csi-rbd-secret
  csi.storage.k8s.io/provisioner-secret-namespace: ceph-csi
  csi.storage.k8s.io/controller-expand-secret-name: csi-rbd-secret
  csi.storage.k8s.io/controller-expand-secret-namespace: ceph-csi
  csi.storage.k8s.io/node-stage-secret-name: csi-rbd-secret
  csi.storage.k8s.io/node-stage-secret-namespace: ceph-csi
reclaimPolicy: Delete
allowVolumeExpansion: true
mountOptions:
  - discard
EOF

echo "== 파드 기동 대기 =="
kubectl -n ceph-csi wait --for=condition=Ready pod -l app=csi-rbdplugin --timeout=120s
kubectl -n ceph-csi wait --for=condition=Ready pod -l app=csi-rbdplugin-provisioner --timeout=120s

echo "완료: ceph-csi 배포, StorageClass 'ceph-csi-rbd' 사용 가능"
