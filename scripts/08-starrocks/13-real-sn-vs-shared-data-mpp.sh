#!/bin/bash
# 진짜 shared-nothing(starrocks-sn, 로컬 XFS) vs 진짜 shared-data(starrocks, RGW)
# 대용량(1000만 행) 로드 + 3-way JOIN(MPP) 재비교. 06-mpp-benchmark.sh와 같은 스키마/쿼리를
# 쓰지만, 이번엔 서로 다른 run_mode를 가진 완전히 별도의 FE 클러스터를 대상으로 한다 —
# 06번은 같은 shared_data FE 안에서 BE/CN을 나눴는데, 그 BE 테이블도 실제로는
# cloud-native였다는 게 뒤늦게 밝혀졌기 때문(work/starrocks-architecture.md 참고).
#
# 사전 조건: 09-deploy-sn-fe.sh, 10-deploy-sn-be.sh(3노드) 실행 완료
# 사용법: ./13-real-sn-vs-shared-data-mpp.sh

set -euo pipefail

FACT_ROWS=10000000
CUSTOMER_ROWS=100000
PRODUCT_ROWS=10000

wait_pod() {
  local ns="$1" pod="$2"
  until [ "$(kubectl -n "$ns" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Running" ] \
     && [ "$(kubectl -n "$ns" get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Pending" ]; do
    sleep 5
  done
}

run_mpp() {
  local ns="$1"
  local fe_host="$2"
  local prefix="$3"           # "real_local" 또는 "real_shared"
  local ddl_properties="$4"

  local slug="${prefix//_/-}"

  echo "== ${ns}/${prefix}: 스키마 생성 =="
  kubectl -n "$ns" delete pod "mpp-schema-${slug}" --ignore-not-found >/dev/null 2>&1
  kubectl -n "$ns" run "mpp-schema-${slug}" --restart=Never --image=mysql:8.0.46 -- \
    mysql -h "$fe_host" -P 9030 -u root -e "
      CREATE DATABASE IF NOT EXISTS bmt_test;
      USE bmt_test;
      CREATE TABLE IF NOT EXISTS ${prefix}_customer (customer_id INT, segment VARCHAR(20), region VARCHAR(20))
      DUPLICATE KEY(customer_id) DISTRIBUTED BY HASH(customer_id) BUCKETS 4 ${ddl_properties};
      CREATE TABLE IF NOT EXISTS ${prefix}_product (product_id INT, category_name VARCHAR(30), unit_price DOUBLE)
      DUPLICATE KEY(product_id) DISTRIBUTED BY HASH(product_id) BUCKETS 4 ${ddl_properties};
      CREATE TABLE IF NOT EXISTS ${prefix}_fact (id BIGINT, customer_id INT, product_id INT, quantity INT, ts DATETIME)
      DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 16 ${ddl_properties};
    " >/dev/null 2>&1
  wait_pod "$ns" "mpp-schema-${slug}"
  kubectl -n "$ns" delete pod "mpp-schema-${slug}" --ignore-not-found >/dev/null 2>&1

  echo "== ${ns}/${prefix}: dimension 로드 (customer ${CUSTOMER_ROWS}, product ${PRODUCT_ROWS}) =="
  kubectl -n "$ns" delete pod "mpp-dims-${slug}" --ignore-not-found >/dev/null 2>&1
  kubectl -n "$ns" run "mpp-dims-${slug}" --restart=Never --image=mysql:8.0.46 -- \
    mysql -h "$fe_host" -P 9030 -u root -e "
      USE bmt_test;
      INSERT INTO ${prefix}_customer SELECT id,
        CASE id % 4 WHEN 0 THEN 'A' WHEN 1 THEN 'B' WHEN 2 THEN 'C' ELSE 'D' END,
        CASE id % 4 WHEN 0 THEN 'east' WHEN 1 THEN 'west' WHEN 2 THEN 'north' ELSE 'south' END
      FROM TABLE(generate_series(1, ${CUSTOMER_ROWS})) AS t(id);
      INSERT INTO ${prefix}_product SELECT id,
        CASE id % 5 WHEN 0 THEN 'electronics' WHEN 1 THEN 'clothing' WHEN 2 THEN 'food' WHEN 3 THEN 'toys' ELSE 'books' END,
        RAND()*100+1
      FROM TABLE(generate_series(1, ${PRODUCT_ROWS})) AS t(id);
    " >/dev/null 2>&1
  wait_pod "$ns" "mpp-dims-${slug}"
  kubectl -n "$ns" delete pod "mpp-dims-${slug}" --ignore-not-found >/dev/null 2>&1

  echo "== ${ns}/${prefix}: fact 로드 (${FACT_ROWS}행) =="
  kubectl -n "$ns" delete pod "mpp-fact-${slug}" --ignore-not-found >/dev/null 2>&1
  kubectl -n "$ns" run "mpp-fact-${slug}" --restart=Never --image=mysql:8.0.46 -- \
    mysql -h "$fe_host" -P 9030 -u root -e "
      USE bmt_test;
      SELECT NOW(6) AS t_load_start;
      INSERT INTO ${prefix}_fact
      SELECT id, (id % ${CUSTOMER_ROWS})+1, (id % ${PRODUCT_ROWS})+1, (id % 10)+1,
             DATE_ADD('2026-01-01 00:00:00', INTERVAL id SECOND)
      FROM TABLE(generate_series(1, ${FACT_ROWS})) AS t(id);
      SELECT NOW(6) AS t_load_end;
    " >/dev/null 2>&1
  wait_pod "$ns" "mpp-fact-${slug}"
  kubectl -n "$ns" logs "mpp-fact-${slug}"
  kubectl -n "$ns" delete pod "mpp-fact-${slug}" --ignore-not-found >/dev/null 2>&1

  echo "== ${ns}/${prefix}: 3-way JOIN + 집계 + 정렬 =="
  kubectl -n "$ns" delete pod "mpp-join-${slug}" --ignore-not-found >/dev/null 2>&1
  kubectl -n "$ns" run "mpp-join-${slug}" --restart=Never --image=mysql:8.0.46 -- \
    mysql -h "$fe_host" -P 9030 -u root -e "
      USE bmt_test;
      SELECT NOW(6) AS t_join_start;
      SELECT c.segment, p.category_name, COUNT(*), SUM(f.quantity * p.unit_price), AVG(f.quantity)
      FROM ${prefix}_fact f
      JOIN ${prefix}_customer c ON f.customer_id = c.customer_id
      JOIN ${prefix}_product p ON f.product_id = p.product_id
      WHERE f.ts BETWEEN '2026-03-01 00:00:00' AND '2026-04-01 00:00:00'
      GROUP BY c.segment, p.category_name
      ORDER BY 4 DESC LIMIT 20;
      SELECT NOW(6) AS t_join_end;
    " >/dev/null 2>&1
  wait_pod "$ns" "mpp-join-${slug}"
  kubectl -n "$ns" logs "mpp-join-${slug}"
  kubectl -n "$ns" delete pod "mpp-join-${slug}" --ignore-not-found >/dev/null 2>&1
}

run_mpp starrocks-sn fe.starrocks-sn.svc.cluster.local real_local 'PROPERTIES("replication_num"="2")'
run_mpp starrocks fe.starrocks.svc.cluster.local real_shared ""

echo "== 정리 =="
kubectl -n starrocks-sn run cleanup-mpp-sn --restart=Never --image=mysql:8.0.46 -- \
  mysql -h fe.starrocks-sn.svc.cluster.local -P 9030 -u root -e "
    DROP TABLE bmt_test.real_local_fact; DROP TABLE bmt_test.real_local_customer; DROP TABLE bmt_test.real_local_product;
  " >/dev/null 2>&1
kubectl -n starrocks run cleanup-mpp-sd --restart=Never --image=mysql:8.0.46 -- \
  mysql -h fe.starrocks.svc.cluster.local -P 9030 -u root -e "
    DROP TABLE bmt_test.real_shared_fact; DROP TABLE bmt_test.real_shared_customer; DROP TABLE bmt_test.real_shared_product;
  " >/dev/null 2>&1
sleep 8
kubectl -n starrocks-sn delete pod cleanup-mpp-sn --ignore-not-found >/dev/null 2>&1
kubectl -n starrocks delete pod cleanup-mpp-sd --ignore-not-found >/dev/null 2>&1

echo "완료. 위 타임스탬프에서 각 t_*_start/t_*_end 차이를 계산해 비교할 것."
