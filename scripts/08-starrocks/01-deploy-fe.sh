#!/bin/bash
# StarRocks FE(Frontend) 배포 — headless Service + 고정 hostname으로 안정적인
# 클러스터 DNS 아이덴티티를 부여한다. 이게 없으면 FE가 자기 자신을 클러스터
# DNS로 못 찾는 임의의 파드 호스트명으로 등록해버려서 CN이 FE에 리포트를 못 한다.
#
# 사전 조건: 00-create-rgw-user-and-bucket.sh 실행 완료(rgw-credentials Secret 존재)
# 사용법: ./01-deploy-fe.sh

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FE_VERSION="4.1.4"

ACCESS_KEY=$(kubectl -n starrocks get secret rgw-credentials -o jsonpath='{.data.access_key}' | base64 -d)
SECRET_KEY=$(kubectl -n starrocks get secret rgw-credentials -o jsonpath='{.data.secret_key}' | base64 -d)

sed -e "s|__ACCESS_KEY__|${ACCESS_KEY}|" -e "s|__SECRET_KEY__|${SECRET_KEY}|" \
  "${DIR}/fe.conf.template" > /tmp/fe.conf.rendered

kubectl -n starrocks create configmap fe-conf \
  --from-file=fe.conf=/tmp/fe.conf.rendered \
  --dry-run=client -o yaml | kubectl apply -f -
rm -f /tmp/fe.conf.rendered

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: fe-hl
  namespace: starrocks
spec:
  clusterIP: None
  selector:
    app: starrocks-fe
  ports:
    - name: query
      port: 9030
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: fe-meta
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
  name: fe
  namespace: starrocks
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: starrocks-fe
  template:
    metadata:
      labels:
        app: starrocks-fe
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
          # 이미지의 기본 CMD가 k8s(tini 경유)에서 인자 없이 호출되어 그냥 usage만 찍고 끝나버린다 —
          # start_fe.sh를 직접 지정해야 한다.
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
  namespace: starrocks
spec:
  selector:
    app: starrocks-fe
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
until [ -n "$(kubectl -n starrocks get pod -l app=starrocks-fe --no-headers 2>/dev/null)" ]; do sleep 5; done
kubectl -n starrocks wait --for=condition=Ready pod -l app=starrocks-fe --timeout=180s

echo "== self-identity 확인 (fe-0.fe-hl... 여야 함, 파드 호스트명이면 잘못된 것) =="
sleep 10
kubectl -n starrocks run mysql-client-fe-check --rm -i --restart=Never --image=mysql:8.0.46 -- \
  mysql -h fe.starrocks.svc.cluster.local -P 9030 -u root -e "SHOW FRONTENDS\G"

echo "완료: FE 배포"
