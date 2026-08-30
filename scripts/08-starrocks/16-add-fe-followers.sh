#!/bin/bash
# FE(코디네이터) 단일 인스턴스가 동시성 병목의 실제 원인인지 검증하기 위해,
# 기존 shared-data(starrocks 네임스페이스) 클러스터에 FE Follower 2개를 추가한다.
# StarRocks는 읽기 쿼리를 리더뿐 아니라 팔로워 FE에서도 처리할 수 있어서(쓰기/DDL만
# 리더 필요), 클라이언트 커넥션을 여러 FE에 나눠 붙이면 코디네이션 부하가 분산될 것으로
# 예상된다.
#
# 사전 조건: 01-deploy-fe.sh로 리더 FE가 이미 떠 있을 것
# 사용법: ./16-add-fe-followers.sh

set -euo pipefail

FE_VERSION="4.1.4"
LEADER_FE_HOST="fe.starrocks.svc.cluster.local"

ACCESS_KEY=$(kubectl -n starrocks get secret rgw-credentials -o jsonpath='{.data.access_key}' | base64 -d)
SECRET_KEY=$(kubectl -n starrocks get secret rgw-credentials -o jsonpath='{.data.secret_key}' | base64 -d)

deploy_follower() {
  local name="$1"   # fe2 또는 fe3
  local node="$2"

  echo "== 리더에 ${name}를 FOLLOWER로 사전 등록 =="
  kubectl -n starrocks delete pod "add-follower-${name}" --ignore-not-found >/dev/null 2>&1
  kubectl -n starrocks run "add-follower-${name}" --restart=Never --image=mysql:8.0.46 -- \
    mysql -h "$LEADER_FE_HOST" -P 9030 -u root \
    -e "ALTER SYSTEM ADD FOLLOWER \"${name}-0.${name}-hl.starrocks.svc.cluster.local:9010\";" >/dev/null 2>&1
  sleep 5
  kubectl -n starrocks delete pod "add-follower-${name}" --ignore-not-found >/dev/null 2>&1

  kubectl -n starrocks create configmap "${name}-conf" \
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
  name: ${name}-hl
  namespace: starrocks
spec:
  clusterIP: None
  selector:
    app: starrocks-${name}
  ports:
    - name: query
      port: 9030
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${name}-meta
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
  name: ${name}
  namespace: starrocks
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: starrocks-${name}
  template:
    metadata:
      labels:
        app: starrocks-${name}
    spec:
      hostname: ${name}-0
      subdomain: ${name}-hl
      nodeSelector:
        kubernetes.io/hostname: ${node}
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
            claimName: ${name}-meta
        - name: shared-conf
          emptyDir: {}
        - name: fe-conf-template
          configMap:
            name: ${name}-conf
---
apiVersion: v1
kind: Service
metadata:
  name: ${name}
  namespace: starrocks
spec:
  selector:
    app: starrocks-${name}
  ports:
    - name: query
      port: 9030
EOF

  echo "== ${name} 기동 대기 =="
  until [ -n "$(kubectl -n starrocks get pod -l app=starrocks-${name} --no-headers 2>/dev/null)" ]; do sleep 5; done
  kubectl -n starrocks wait --for=condition=Ready pod -l app=starrocks-${name} --timeout=180s
}

deploy_follower fe2 chan09
deploy_follower fe3 llm001

echo "== 전체 FE 상태 확인 (Role: FOLLOWER, Alive: true 여야 함) =="
sleep 15
kubectl -n starrocks delete pod fe-status-check --ignore-not-found >/dev/null 2>&1
kubectl -n starrocks run fe-status-check --restart=Never --image=mysql:8.0.46 -- \
  mysql -h "$LEADER_FE_HOST" -P 9030 -u root -e "SHOW FRONTENDS\G" >/dev/null 2>&1
sleep 5
kubectl -n starrocks logs fe-status-check | grep -E "Name|Role|Alive"
kubectl -n starrocks delete pod fe-status-check --ignore-not-found >/dev/null 2>&1

echo "완료: fe2(chan09), fe3(llm001) FOLLOWER 추가"
