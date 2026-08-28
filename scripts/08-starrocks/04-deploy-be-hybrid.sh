#!/bin/bash
# 기존 shared-data FE(run_mode=shared_data, CN 이미 등록됨)에 BE를 추가로 등록해
# 하이브리드(로컬 BE + 공유 CN)로 구성한다.
#
# 검증 결과(2026-08-28): 공식 문서는 "shared-nothing/shared-data 혼합 배포 미지원"이라고
# 되어 있지만, 실제로는 run_mode=shared_data로 생성된 클러스터에 BE를 추가 등록하는 것
# 자체는 된다 — 별도 FE/클러스터 없이 가능. replication_num 등 특별한 property 없이 그냥
# CREATE TABLE하면 자동으로 BE(로컬)로 라우팅되고, 기존 CN(오브젝트 스토리지) 테이블과
# 동시에 조회 가능하다. 자세한 내용은 work/starrocks-architecture.md 참고.
#
# 사전 조건: scripts/07-ceph-storage/12-resplit-osd-disk.sh로 대상 노드에 XFS 파티션이
#            준비되어 있어야 함(기본값: /mnt/starrocks-be)
# 사용법: ./04-deploy-be-hybrid.sh <노드 hostname, 예: chan08>

set -euo pipefail

NODE="${1:-}"
if [[ -z "$NODE" ]]; then
  echo "사용법: $0 <노드 hostname>" >&2
  exit 1
fi

BE_VERSION="4.1.4"
XFS_PATH="/mnt/starrocks-be"

kubectl -n starrocks create configmap be-conf \
  --from-literal=be.conf="$(cat <<EOF
sys_log_level = INFO
be_port = 9060
brpc_port = 8060
heartbeat_service_port = 9050
storage_root_path = /opt/starrocks/be/storage
EOF
)" --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: be-hl
  namespace: starrocks
spec:
  clusterIP: None
  selector:
    app: starrocks-be
  ports:
    - name: heartbeat
      port: 9050
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: be
  namespace: starrocks
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: starrocks-be
  template:
    metadata:
      labels:
        app: starrocks-be
    spec:
      hostname: be-0
      subdomain: be-hl
      nodeSelector:
        kubernetes.io/hostname: ${NODE}
      initContainers:
        - name: conf-init
          image: starrocks/be-ubuntu:${BE_VERSION}
          command: ["sh", "-c", "cp -r /opt/starrocks/be/conf/* /shared-conf/ && cp /template/be.conf /shared-conf/be.conf"]
          volumeMounts:
            - name: shared-conf
              mountPath: /shared-conf
            - name: be-conf-template
              mountPath: /template
      containers:
        - name: be
          image: starrocks/be-ubuntu:${BE_VERSION}
          command: ["/opt/starrocks/be/bin/start_be.sh"]
          args: ["--host_type", "FQDN"]
          ports:
            - containerPort: 9060
            - containerPort: 8060
            - containerPort: 9050
          volumeMounts:
            - name: shared-conf
              mountPath: /opt/starrocks/be/conf
            - name: storage
              mountPath: /opt/starrocks/be/storage
          resources:
            limits:
              memory: 4Gi
            requests:
              memory: 2Gi
      volumes:
        - name: shared-conf
          emptyDir: {}
        - name: be-conf-template
          configMap:
            name: be-conf
        - name: storage
          hostPath:
            path: ${XFS_PATH}
            type: Directory
EOF

echo "== BE 기동 대기 =="
kubectl -n starrocks wait --for=condition=Ready pod -l app=starrocks-be --timeout=180s

echo "== 기존 FE에 BE 등록 =="
kubectl -n starrocks run mysql-client-add-be --rm -i --restart=Never --image=mysql:8.0.46 -- \
  mysql -h fe.starrocks.svc.cluster.local -P 9030 -u root \
  -e 'ALTER SYSTEM ADD BACKEND "be-0.be-hl.starrocks.svc.cluster.local:9050";'

echo "== 등록 확인 =="
sleep 15
kubectl -n starrocks run mysql-client-check-be --rm -i --restart=Never --image=mysql:8.0.46 -- \
  mysql -h fe.starrocks.svc.cluster.local -P 9030 -u root -e "SHOW BACKENDS\G"

echo "완료: BE 배포 및 등록. property 없이 CREATE TABLE하면 자동으로 이 BE(로컬)로 라우팅된다."
