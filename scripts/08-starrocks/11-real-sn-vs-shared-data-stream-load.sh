#!/bin/bash
# shared-nothing(starrocks-sn 네임스페이스, run_mode 기본값, 로컬 XFS에 실제 저장)
# vs shared-data(starrocks 네임스페이스, run_mode=shared_data, RGW에 실제 저장)
# STREAM LOAD 순수 쓰기 I/O 비교.
#
# 사전 조건: 09-deploy-sn-fe.sh, 10-deploy-sn-be.sh(3노드) 실행 완료
# 사용법: 대상 노드(예: chan08)에서 실행
#   ./11-real-sn-vs-shared-data-stream-load.sh [행 수, 기본 10000000]

set -euo pipefail

ROWS="${1:-10000000}"
CSV_PATH="/tmp/hc_data.csv"
SN_FE_HOST="fe.starrocks-sn.svc.cluster.local"
SD_FE_HOST="fe.starrocks.svc.cluster.local"

echo "== CSV 사전 생성 (${ROWS}행, 측정 대상 아님) =="
python3 -c "
import hashlib, random, time
t0 = time.time()
with open('${CSV_PATH}', 'w') as f:
    for i in range(1, ${ROWS}+1):
        cust = random.randint(1, 100000)
        prod = random.randint(1, 10000)
        qty = random.randint(1, 10)
        payload = ''.join(hashlib.md5(f'{i}{random.random()}{j}'.encode()).hexdigest() for j in range(8))
        f.write(f'{i},{cust},{prod},{qty},2026-01-01 00:00:00,{payload}\n')
print('generated in', time.time()-t0, 's')
"
ls -lh "$CSV_PATH"

echo "== 진짜 shared-nothing(starrocks-sn) 테이블 생성 =="
kubectl -n starrocks-sn delete pod sn-schema --ignore-not-found >/dev/null 2>&1
kubectl -n starrocks-sn run sn-schema --restart=Never --image=mysql:8.0.46 -- \
  mysql -h "$SN_FE_HOST" -P 9030 -u root -e "
    CREATE DATABASE IF NOT EXISTS bmt_test;
    USE bmt_test;
    CREATE TABLE IF NOT EXISTS real_local_fact (id BIGINT, customer_id INT, product_id INT, quantity INT, ts DATETIME, payload VARCHAR(500))
    DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 16 PROPERTIES(\"replication_num\"=\"2\");
  " >/dev/null 2>&1
until [ "$(kubectl -n starrocks-sn get pod sn-schema -o jsonpath='{.status.phase}' 2>/dev/null)" != "Running" ] \
   && [ "$(kubectl -n starrocks-sn get pod sn-schema -o jsonpath='{.status.phase}' 2>/dev/null)" != "Pending" ]; do
  sleep 5
done
kubectl -n starrocks-sn delete pod sn-schema --ignore-not-found >/dev/null 2>&1

echo "== shared-data(starrocks, cloud-native/RGW) 테이블 생성 =="
kubectl -n starrocks delete pod sd-schema --ignore-not-found >/dev/null 2>&1
kubectl -n starrocks run sd-schema --restart=Never --image=mysql:8.0.46 -- \
  mysql -h "$SD_FE_HOST" -P 9030 -u root -e "
    USE bmt_test;
    CREATE TABLE IF NOT EXISTS real_shared_fact (id BIGINT, customer_id INT, product_id INT, quantity INT, ts DATETIME, payload VARCHAR(500))
    DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 16;
  " >/dev/null 2>&1
until [ "$(kubectl -n starrocks get pod sd-schema -o jsonpath='{.status.phase}' 2>/dev/null)" != "Running" ] \
   && [ "$(kubectl -n starrocks get pod sd-schema -o jsonpath='{.status.phase}' 2>/dev/null)" != "Pending" ]; do
  sleep 5
done
kubectl -n starrocks delete pod sd-schema --ignore-not-found >/dev/null 2>&1

echo "== STREAM LOAD 클라이언트 파드 생성(CSV가 있는 노드에 hostPath로 붙임, starrocks-sn 네임스페이스) =="
CURRENT_NODE=$(hostname)
kubectl -n starrocks-sn delete pod stream-load-client --ignore-not-found >/dev/null 2>&1
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: stream-load-client
  namespace: starrocks-sn
spec:
  nodeSelector:
    kubernetes.io/hostname: ${CURRENT_NODE}
  containers:
    - name: curl
      image: curlimages/curl:8.10.1
      command: ["sleep", "3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      hostPath:
        path: /tmp
EOF
kubectl -n starrocks-sn wait --for=condition=Ready pod/stream-load-client --timeout=60s

echo "== 진짜 로컬(shared-nothing) STREAM LOAD =="
kubectl -n starrocks-sn exec stream-load-client -- curl -s --location-trusted -u root: \
  -H "label:real_local_$(date +%s)" \
  -H "column_separator:," \
  -H "columns: id,customer_id,product_id,quantity,ts,payload" \
  -T /data/hc_data.csv \
  "http://${SN_FE_HOST}:8030/api/bmt_test/real_local_fact/_stream_load"

echo "== 진짜 공유(shared-data/RGW) STREAM LOAD =="
kubectl -n starrocks-sn exec stream-load-client -- curl -s --location-trusted -u root: \
  -H "label:real_shared_$(date +%s)" \
  -H "column_separator:," \
  -H "columns: id,customer_id,product_id,quantity,ts,payload" \
  -T /data/hc_data.csv \
  "http://${SD_FE_HOST}:8030/api/bmt_test/real_shared_fact/_stream_load"

echo "== 정리 =="
kubectl -n starrocks-sn delete pod stream-load-client --ignore-not-found >/dev/null 2>&1
kubectl -n starrocks-sn delete pod cleanup-sn --ignore-not-found >/dev/null 2>&1
kubectl -n starrocks-sn run cleanup-sn --restart=Never --image=mysql:8.0.46 -- \
  mysql -h "$SN_FE_HOST" -P 9030 -u root -e "DROP TABLE bmt_test.real_local_fact;" >/dev/null 2>&1
kubectl -n starrocks delete pod cleanup-sd --ignore-not-found >/dev/null 2>&1
kubectl -n starrocks run cleanup-sd --restart=Never --image=mysql:8.0.46 -- \
  mysql -h "$SD_FE_HOST" -P 9030 -u root -e "DROP TABLE bmt_test.real_shared_fact;" >/dev/null 2>&1
sleep 8
kubectl -n starrocks-sn delete pod cleanup-sn --ignore-not-found >/dev/null 2>&1
kubectl -n starrocks delete pod cleanup-sd --ignore-not-found >/dev/null 2>&1
rm -f "$CSV_PATH"

echo "완료. 각 STREAM LOAD 응답의 LoadTimeMs/WriteDataTimeMs/LoadBytes로 비교할 것."
