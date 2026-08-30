#!/bin/bash
# starrocks-sn(진짜 shared-nothing) FE에 로컬 스토리지 BE를 추가 등록한다.
# hostPath는 각 노드의 로컬 XFS 파티션(/mnt/local-data, KVM VM 디스크와도 같이
# 쓰는 범용 파티션 — lessons/06-kvm.md 참고)의 하위 디렉토리(sn-data)를 써서,
# 같은 노드의 starrocks 네임스페이스(shared_data) BE가 쓰는 datacache와 물리적으로
# 겹치지 않게 분리한다.
#
# 사전 조건: 09-deploy-sn-fe.sh 실행 완료, 대상 노드에 /mnt/local-data/sn-data 존재
# 사용법: ./10-deploy-sn-be.sh <노드 hostname> <배포 이름 접미사, 예: 1/2/3>

set -euo pipefail

NODE="${1:-}"
SUFFIX="${2:-}"
if [[ -z "$NODE" || -z "$SUFFIX" ]]; then
  echo "사용법: $0 <노드 hostname> <접미사>" >&2
  exit 1
fi

BE_VERSION="4.1.4"
XFS_PATH="/mnt/local-data/sn-data"
NAME="sn-be${SUFFIX}"

kubectl -n starrocks-sn create configmap "${NAME}-conf" \
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
  name: ${NAME}-hl
  namespace: starrocks-sn
spec:
  clusterIP: None
  selector:
    app: starrocks-${NAME}
  ports:
    - name: heartbeat
      port: 9050
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${NAME}
  namespace: starrocks-sn
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: starrocks-${NAME}
  template:
    metadata:
      labels:
        app: starrocks-${NAME}
    spec:
      hostname: ${NAME}-0
      subdomain: ${NAME}-hl
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
            name: ${NAME}-conf
        - name: storage
          hostPath:
            path: ${XFS_PATH}
            type: Directory
EOF

echo "== ${NAME} 기동 대기 =="
kubectl -n starrocks-sn wait --for=condition=Ready pod -l app=starrocks-${NAME} --timeout=180s

echo "== FE에 등록 =="
kubectl -n starrocks-sn run mysql-client-add-${NAME} --rm -i --restart=Never --image=mysql:8.0.46 -- \
  mysql -h fe.starrocks-sn.svc.cluster.local -P 9030 -u root \
  -e "ALTER SYSTEM ADD BACKEND \"${NAME}-0.${NAME}-hl.starrocks-sn.svc.cluster.local:9050\";"

echo "완료: ${NAME} 배포 및 등록 (노드: ${NODE})"
