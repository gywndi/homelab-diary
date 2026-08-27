#!/bin/bash
# StarRocks CN(Compute Node) 배포 + FE 등록.
# FE와 동일하게 headless Service + 고정 hostname으로 안정적인 DNS 아이덴티티를
# 부여한다 — IP로 등록하면 파드 재시작마다 재등록이 필요해진다.
#
# 사전 조건: 01-deploy-fe.sh 완료(FE가 Alive 상태)
# 사용법: ./02-deploy-cn.sh

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CN_VERSION="4.1.4"

kubectl -n starrocks create configmap cn-conf \
  --from-file=cn.conf="${DIR}/cn.conf" \
  --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: cn-hl
  namespace: starrocks
spec:
  clusterIP: None
  selector:
    app: starrocks-cn
  ports:
    - name: heartbeat
      port: 9050
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cn
  namespace: starrocks
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: starrocks-cn
  template:
    metadata:
      labels:
        app: starrocks-cn
    spec:
      hostname: cn-0
      subdomain: cn-hl
      initContainers:
        - name: conf-init
          image: starrocks/cn-ubuntu:${CN_VERSION}
          command: ["sh", "-c", "cp -r /opt/starrocks/cn/conf/* /shared-conf/ && cp /template/cn.conf /shared-conf/cn.conf"]
          volumeMounts:
            - name: shared-conf
              mountPath: /shared-conf
            - name: cn-conf-template
              mountPath: /template
      containers:
        - name: cn
          image: starrocks/cn-ubuntu:${CN_VERSION}
          command: ["/opt/starrocks/cn/bin/start_cn.sh"]
          args: ["--host_type", "FQDN"]
          ports:
            - containerPort: 9060
            - containerPort: 8060
            - containerPort: 9050
            - containerPort: 9070
          volumeMounts:
            - name: shared-conf
              mountPath: /opt/starrocks/cn/conf
          resources:
            limits:
              memory: 4Gi
            requests:
              memory: 2Gi
      volumes:
        - name: shared-conf
          emptyDir: {}
        - name: cn-conf-template
          configMap:
            name: cn-conf
---
apiVersion: v1
kind: Service
metadata:
  name: cn
  namespace: starrocks
spec:
  selector:
    app: starrocks-cn
  ports:
    - name: be
      port: 9060
    - name: brpc
      port: 8060
    - name: heartbeat
      port: 9050
    - name: starlet
      port: 9070
EOF

echo "== CN 기동 대기 =="
kubectl -n starrocks wait --for=condition=Ready pod -l app=starrocks-cn --timeout=180s

echo "== FE에 CN 등록 (headless Service FQDN 사용 — IP로 등록하면 파드 재시작마다 깨짐) =="
kubectl -n starrocks run mysql-client-cn-add --rm -i --restart=Never --image=mysql:8.0.46 -- \
  mysql -h fe.starrocks.svc.cluster.local -P 9030 -u root \
  -e 'ALTER SYSTEM ADD COMPUTE NODE "cn-0.cn-hl.starrocks.svc.cluster.local:9050";'

echo "== 등록 확인 (수 초 후 Alive=true, StatusCode=OK 여야 함) =="
sleep 15
kubectl -n starrocks run mysql-client-cn-check --rm -i --restart=Never --image=mysql:8.0.46 -- \
  mysql -h fe.starrocks.svc.cluster.local -P 9030 -u root -e "SHOW COMPUTE NODES\G"

echo "완료: CN 배포 및 등록"
