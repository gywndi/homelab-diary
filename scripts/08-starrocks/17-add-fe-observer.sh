#!/bin/bash
# shared-data(starrocks 네임스페이스) 클러스터에 FE Observer 1개를 추가한다.
# Observer는 메타데이터를 읽기 전용으로 복제만 받고 BDBJE(FE 리더 선출/메타데이터
# 복제에 쓰는 라이브러리) 쿼럼 투표엔 참여하지 않는다 — Follower(투표 멤버)를 늘리면
# 메타데이터 쓰기마다 필요한 과반수 확인이 느려지지만, Observer는 투표에 안 끼어서
# 이 비용 없이 쿼리 코디네이션(Parser/Analyzer/CBO/Coordinator) 처리량만 늘릴 수 있다.
#
# 사전 조건: 01-deploy-fe.sh로 리더 FE가 이미 떠 있을 것
# 사용법: ./17-add-fe-observer.sh <이름, 예: fe-obs1> <배치할 노드, 예: chan09>

set -euo pipefail

NAME="${1:-}"
NODE="${2:-}"
if [[ -z "$NAME" || -z "$NODE" ]]; then
  echo "사용법: $0 <이름> <배치할 노드>" >&2
  exit 1
fi

FE_VERSION="4.1.4"
LEADER_FE_HOST="fe.starrocks.svc.cluster.local"

ACCESS_KEY=$(kubectl -n starrocks get secret rgw-credentials -o jsonpath='{.data.access_key}' | base64 -d)
SECRET_KEY=$(kubectl -n starrocks get secret rgw-credentials -o jsonpath='{.data.secret_key}' | base64 -d)

echo "== 리더에 ${NAME}를 OBSERVER로 사전 등록 =="
kubectl -n starrocks delete pod "add-observer-${NAME}" --ignore-not-found >/dev/null 2>&1
kubectl -n starrocks run "add-observer-${NAME}" --restart=Never --image=mysql:8.0.46 -- \
  mysql -h "$LEADER_FE_HOST" -P 9030 -u root \
  -e "ALTER SYSTEM ADD OBSERVER \"${NAME}-0.${NAME}-hl.starrocks.svc.cluster.local:9010\";" >/dev/null 2>&1
sleep 5
kubectl -n starrocks delete pod "add-observer-${NAME}" --ignore-not-found >/dev/null 2>&1

kubectl -n starrocks create configmap "${NAME}-conf" \
  --from-literal=fe.conf="$(cat <<EOF
http_port = 8030
rpc_port = 9020
query_port = 9030
edit_log_port = 9010
mysql_service_nio_enabled = true
sys_log_level = INFO
run_mode = shared_data
cloud_native_storage_type = S3
cloud_native_meta_port = 6090
enable_load_volume_from_conf = true
tablet_create_timeout_second = 60
aws_s3_path = starrocks-storage
aws_s3_region = default
aws_s3_endpoint = http://10.5.5.4:7480
aws_s3_use_aws_sdk_default_behavior = false
aws_s3_use_instance_profile = false
aws_s3_access_key = ${ACCESS_KEY}
aws_s3_secret_key = ${SECRET_KEY}
EOF
)" --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: ${NAME}-hl
  namespace: starrocks
spec:
  clusterIP: None
  selector:
    app: starrocks-${NAME}
  ports:
    - name: query
      port: 9030
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${NAME}-meta
  namespace: starrocks
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ceph-csi-rbd
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${NAME}
  namespace: starrocks
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
          image: starrocks/fe-ubuntu:${FE_VERSION}
          command: ["sh", "-c", "cp -r /opt/starrocks/fe/conf/* /shared-conf/ && cp /template/fe.conf /shared-conf/fe.conf"]
          volumeMounts:
            - name: shared-conf
              mountPath: /shared-conf
            - name: fe-conf-template
              mountPath: /template
      containers:
        - name: fe
          image: starrocks/fe-ubuntu:${FE_VERSION}
          command: ["/opt/starrocks/fe/bin/start_fe.sh"]
          args: ["--host_type", "FQDN", "--helper", "fe-0.fe-hl.starrocks.svc.cluster.local:9010"]
          ports:
            - containerPort: 8030
            - containerPort: 9020
            - containerPort: 9030
            - containerPort: 9010
          volumeMounts:
            - name: meta
              mountPath: /opt/starrocks/fe/meta
            - name: shared-conf
              mountPath: /opt/starrocks/fe/conf
          resources:
            limits:
              memory: 3Gi
            requests:
              memory: 2Gi
      volumes:
        - name: meta
          persistentVolumeClaim:
            claimName: ${NAME}-meta
        - name: shared-conf
          emptyDir: {}
        - name: fe-conf-template
          configMap:
            name: ${NAME}-conf
---
apiVersion: v1
kind: Service
metadata:
  name: ${NAME}
  namespace: starrocks
spec:
  selector:
    app: starrocks-${NAME}
  ports:
    - name: query
      port: 9030
EOF

echo "== ${NAME} 기동 대기 =="
until [ -n "$(kubectl -n starrocks get pod -l app=starrocks-${NAME} --no-headers 2>/dev/null)" ]; do sleep 5; done
kubectl -n starrocks wait --for=condition=Ready pod -l app=starrocks-${NAME} --timeout=180s

echo "== 전체 FE 상태 확인 (Role: OBSERVER, Alive: true 여야 함) =="
sleep 15
kubectl -n starrocks delete pod fe-status-check --ignore-not-found >/dev/null 2>&1
kubectl -n starrocks run fe-status-check --restart=Never --image=mysql:8.0.46 -- \
  mysql -h "$LEADER_FE_HOST" -P 9030 -u root -e "SHOW FRONTENDS\G" >/dev/null 2>&1
sleep 5
kubectl -n starrocks logs fe-status-check | grep -E "Name|Role|Alive"
kubectl -n starrocks delete pod fe-status-check --ignore-not-found >/dev/null 2>&1

echo "완료: ${NAME}(${NODE}) OBSERVER 추가"
