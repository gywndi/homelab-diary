#!/bin/bash
# 진짜 shared-nothing(run_mode 기본값, RGW/S3 설정 전혀 없음) FE를 별도 네임스페이스
# (starrocks-sn)에 배포한다. 기존 starrocks 네임스페이스의 FE는 run_mode=shared_data라
# 아무리 replication_num을 지정해도 모든 테이블이 cloud-native(RGW 기반)로 만들어진다 —
# 진짜 로컬 스토리지 비교를 하려면 별도 클러스터가 필요하다. StarRocks는 한 클러스터에서
# shared_nothing/shared_data 혼합 배포를 지원하지 않는다(공식 문서로 확인).
#
# 사용법: ./09-deploy-sn-fe.sh

set -euo pipefail

FE_VERSION="4.1.4"

kubectl create namespace starrocks-sn --dry-run=client -o yaml | kubectl apply -f -

kubectl -n starrocks-sn create configmap fe-conf \
  --from-literal=fe.conf="$(cat <<'EOF'
LOG_DIR = ${STARROCKS_HOME}/log
JAVA_OPTS="-Dlog4j2.formatMsgNoLookups=true -Xmx2048m -XX:+UseG1GC"
http_port = 8030
rpc_port = 9020
query_port = 9030
edit_log_port = 9010
mysql_service_nio_enabled = true
sys_log_level = INFO
tablet_create_timeout_second = 60
EOF
)" --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: fe-hl
  namespace: starrocks-sn
spec:
  clusterIP: None
  selector:
    app: starrocks-sn-fe
  ports:
    - name: query
      port: 9030
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: fe-meta
  namespace: starrocks-sn
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
  name: fe
  namespace: starrocks-sn
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: starrocks-sn-fe
  template:
    metadata:
      labels:
        app: starrocks-sn-fe
    spec:
      hostname: fe-0
      subdomain: fe-hl
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
          args: ["--host_type", "FQDN"]
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
            claimName: fe-meta
        - name: shared-conf
          emptyDir: {}
        - name: fe-conf-template
          configMap:
            name: fe-conf
---
apiVersion: v1
kind: Service
metadata:
  name: fe
  namespace: starrocks-sn
spec:
  selector:
    app: starrocks-sn-fe
  ports:
    - name: http
      port: 8030
    - name: rpc
      port: 9020
    - name: query
      port: 9030
    - name: edit-log
      port: 9010
EOF

echo "== FE 기동 대기 =="
until [ -n "$(kubectl -n starrocks-sn get pod -l app=starrocks-sn-fe --no-headers 2>/dev/null)" ]; do sleep 5; done
kubectl -n starrocks-sn wait --for=condition=Ready pod -l app=starrocks-sn-fe --timeout=180s

echo "== self-identity 확인 =="
sleep 10
kubectl -n starrocks-sn run mysql-client-fe-check --rm -i --restart=Never --image=mysql:8.0.46 -- \
  mysql -h fe.starrocks-sn.svc.cluster.local -P 9030 -u root -e "SHOW FRONTENDS\G"

echo "완료: shared-nothing FE 배포 (네임스페이스: starrocks-sn)"
