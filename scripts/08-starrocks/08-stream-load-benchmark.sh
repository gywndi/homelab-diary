#!/bin/bash
# shared-nothing(BE) vs shared-data(CN) 순수 쓰기 I/O 비교 — STREAM LOAD 버전.
# 06/07번 스크립트는 INSERT...SELECT로 데이터를 서버에서 즉석 생성하는데, 고카디널리티
# payload(MD5)를 쓰면 그 계산 자체의 CPU 비용이 규모가 커질수록 스토리지 I/O 비용을
# 가려버린다(자세한 내용은 work/starrocks-architecture.md 참고). 이 스크립트는 데이터
# 생성을 완전히 분리한다 — 로컬에서 CSV 파일을 미리 만들어두고, STREAM LOAD(HTTP PUT
# 기반 벌크 로드)로 순수 파싱+쓰기 시간만 측정한다.
#
# 결과 예시(2026-08-28, 1000만 행, ~2.8GB): BE 67.3초 vs CN 55.6초 — CN이 오히려 빠름.
# INSERT...SELECT 방식(CN이 22% 느림)과 정반대 결과가 나온 이유는 BE도 replication_num=2라
# 두 번째 복제본을 다른 BE로 네트워크 전송해야 하기 때문으로 추정 — "로컬이라 항상 빠르다"는
# 통념이 레플리카 2개 이상에서는 성립하지 않을 수 있다는 걸 보여준다.
#
# 사전 조건: CN, BE 각각 최소 1개 이상 등록, python3 사용 가능한 노드에서 실행
# 사용법: 대상 노드(예: chan08)에서 실행
#   ./08-stream-load-benchmark.sh [행 수, 기본 10000000]

set -euo pipefail

ROWS="${1:-10000000}"
CSV_PATH="/tmp/hc_data.csv"
FE_HOST="fe.starrocks.svc.cluster.local"

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

echo "== 테이블 생성 =="
kubectl -n starrocks delete pod sl-schema --ignore-not-found >/dev/null 2>&1
kubectl -n starrocks run sl-schema --restart=Never --image=mysql:8.0.46 -- \
  mysql -h "$FE_HOST" -P 9030 -u root -e "
    USE bmt_test;
    CREATE TABLE IF NOT EXISTS sl_local_fact (id BIGINT, customer_id INT, product_id INT, quantity INT, ts DATETIME, payload VARCHAR(500))
    DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 16 PROPERTIES(\"replication_num\"=\"2\");
    CREATE TABLE IF NOT EXISTS sl_shared_fact (id BIGINT, customer_id INT, product_id INT, quantity INT, ts DATETIME, payload VARCHAR(500))
    DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 16;
  " >/dev/null 2>&1
until [ "$(kubectl -n starrocks get pod sl-schema -o jsonpath='{.status.phase}' 2>/dev/null)" != "Running" ] \
   && [ "$(kubectl -n starrocks get pod sl-schema -o jsonpath='{.status.phase}' 2>/dev/null)" != "Pending" ]; do
  sleep 5
done
kubectl -n starrocks delete pod sl-schema --ignore-not-found >/dev/null 2>&1

echo "== STREAM LOAD 클라이언트 파드 생성(CSV가 있는 노드에 hostPath로 붙임) =="
CURRENT_NODE=$(hostname)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: stream-load-client
  namespace: starrocks
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
kubectl -n starrocks wait --for=condition=Ready pod/stream-load-client --timeout=60s

echo "== BE(로컬) STREAM LOAD =="
kubectl -n starrocks exec stream-load-client -- curl -s --location-trusted -u root: \
  -H "label:sl_local_$(date +%s)" \
  -H "column_separator:," \
  -H "columns: id,customer_id,product_id,quantity,ts,payload" \
  -T /data/hc_data.csv \
  "http://${FE_HOST}:8030/api/bmt_test/sl_local_fact/_stream_load"

echo "== CN(RGW) STREAM LOAD =="
kubectl -n starrocks exec stream-load-client -- curl -s --location-trusted -u root: \
  -H "label:sl_shared_$(date +%s)" \
  -H "column_separator:," \
  -H "columns: id,customer_id,product_id,quantity,ts,payload" \
  -T /data/hc_data.csv \
  "http://${FE_HOST}:8030/api/bmt_test/sl_shared_fact/_stream_load"

echo "== 정리 =="
kubectl -n starrocks delete pod stream-load-client --ignore-not-found >/dev/null 2>&1
kubectl -n starrocks delete pod cleanup-sl --ignore-not-found >/dev/null 2>&1
kubectl -n starrocks run cleanup-sl --restart=Never --image=mysql:8.0.46 -- \
  mysql -h "$FE_HOST" -P 9030 -u root -e "DROP TABLE bmt_test.sl_local_fact; DROP TABLE bmt_test.sl_shared_fact;" >/dev/null 2>&1
sleep 8
kubectl -n starrocks delete pod cleanup-sl --ignore-not-found >/dev/null 2>&1
rm -f "$CSV_PATH"

echo "완료. 각 STREAM LOAD 응답의 LoadTimeMs/WriteDataTimeMs/LoadBytes로 비교할 것."
