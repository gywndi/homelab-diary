#!/bin/bash
# shared-nothing(BE) vs shared-data(CN) 대용량 로드 + 복잡한 3-way JOIN(MPP) 비교.
# fact(1000만 행) + customer(10만) + product(1만) 스타 스키마를 양쪽에 만들고
# 동일한 조인/집계/정렬 쿼리를 돌려 시간을 비교한다.
#
# 사전 조건:
#   - CN, BE 각각 최소 1개 이상 등록되어 있을 것
#   - 여러 노드에 걸친 진짜 MPP 병렬성을 보려면 CN/BE를 노드마다 하나씩 배포해둘 것
#     (scripts/08-starrocks/02-deploy-cn.sh, 04-deploy-be-hybrid.sh를 노드별로 반복)
#
# 사용법: ./06-mpp-benchmark.sh
#   결과는 stdout에 각 단계 시작/종료 타임스탬프로 출력된다 — 직접 밀리초 차이를 계산할 것

set -euo pipefail

FE_HOST="fe.starrocks.svc.cluster.local"
FACT_ROWS=10000000
CUSTOMER_ROWS=100000
PRODUCT_ROWS=10000

wait_pod() {
  local pod="$1"
  until [ "$(kubectl -n starrocks get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Running" ] \
     && [ "$(kubectl -n starrocks get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Pending" ]; do
    sleep 5
  done
}

run_mpp() {
  local prefix="$1"           # "local" 또는 "shared"
  local ddl_properties="$2"   # BE는 'PROPERTIES("replication_num"="2")', CN은 ''

  echo "== ${prefix}: 스키마 생성 (최초 1회는 콜드 스타트로 느릴 수 있음) =="
  kubectl -n starrocks delete pod "mpp-schema-${prefix}" --ignore-not-found >/dev/null 2>&1
  kubectl -n starrocks run "mpp-schema-${prefix}" --restart=Never --image=mysql:8.0.46 -- \
    mysql -h "$FE_HOST" -P 9030 -u root -e "
      USE bmt_test;
      CREATE TABLE IF NOT EXISTS ${prefix}_customer (customer_id INT, segment VARCHAR(20), region VARCHAR(20))
      DUPLICATE KEY(customer_id) DISTRIBUTED BY HASH(customer_id) BUCKETS 4 ${ddl_properties};
      CREATE TABLE IF NOT EXISTS ${prefix}_product (product_id INT, category_name VARCHAR(30), unit_price DOUBLE)
      DUPLICATE KEY(product_id) DISTRIBUTED BY HASH(product_id) BUCKETS 4 ${ddl_properties};
      CREATE TABLE IF NOT EXISTS ${prefix}_fact (id BIGINT, customer_id INT, product_id INT, quantity INT, ts DATETIME)
      DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 16 ${ddl_properties};
    " >/dev/null 2>&1
  wait_pod "mpp-schema-${prefix}"
  kubectl -n starrocks delete pod "mpp-schema-${prefix}" --ignore-not-found >/dev/null 2>&1

  echo "== ${prefix}: dimension 로드 (customer ${CUSTOMER_ROWS}, product ${PRODUCT_ROWS}) =="
  kubectl -n starrocks delete pod "mpp-dims-${prefix}" --ignore-not-found >/dev/null 2>&1
  kubectl -n starrocks run "mpp-dims-${prefix}" --restart=Never --image=mysql:8.0.46 -- \
    mysql -h "$FE_HOST" -P 9030 -u root -e "
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
  wait_pod "mpp-dims-${prefix}"
  kubectl -n starrocks delete pod "mpp-dims-${prefix}" --ignore-not-found >/dev/null 2>&1

  echo "== ${prefix}: fact 로드 (${FACT_ROWS}행) =="
  kubectl -n starrocks delete pod "mpp-fact-${prefix}" --ignore-not-found >/dev/null 2>&1
  kubectl -n starrocks run "mpp-fact-${prefix}" --restart=Never --image=mysql:8.0.46 -- \
    mysql -h "$FE_HOST" -P 9030 -u root -e "
      USE bmt_test;
      SELECT NOW(6) AS t_load_start;
      INSERT INTO ${prefix}_fact
      SELECT id, (id % ${CUSTOMER_ROWS})+1, (id % ${PRODUCT_ROWS})+1, (id % 10)+1,
             DATE_ADD('2026-01-01 00:00:00', INTERVAL id SECOND)
      FROM TABLE(generate_series(1, ${FACT_ROWS})) AS t(id);
      SELECT NOW(6) AS t_load_end;
    " >/dev/null 2>&1
  wait_pod "mpp-fact-${prefix}"
  kubectl -n starrocks logs "mpp-fact-${prefix}"
  kubectl -n starrocks delete pod "mpp-fact-${prefix}" --ignore-not-found >/dev/null 2>&1

  echo "== ${prefix}: 3-way JOIN + 집계 + 정렬 =="
  kubectl -n starrocks delete pod "mpp-join-${prefix}" --ignore-not-found >/dev/null 2>&1
  kubectl -n starrocks run "mpp-join-${prefix}" --restart=Never --image=mysql:8.0.46 -- \
    mysql -h "$FE_HOST" -P 9030 -u root -e "
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
  wait_pod "mpp-join-${prefix}"
  kubectl -n starrocks logs "mpp-join-${prefix}"
  kubectl -n starrocks delete pod "mpp-join-${prefix}" --ignore-not-found >/dev/null 2>&1
}

run_mpp "local" 'PROPERTIES("replication_num"="2")'
run_mpp "shared" ""

echo "== 정리 =="
kubectl -n starrocks delete pod cleanup-mpp --ignore-not-found >/dev/null 2>&1
kubectl -n starrocks run cleanup-mpp --restart=Never --image=mysql:8.0.46 -- \
  mysql -h "$FE_HOST" -P 9030 -u root -e "
    DROP TABLE bmt_test.local_fact; DROP TABLE bmt_test.local_customer; DROP TABLE bmt_test.local_product;
    DROP TABLE bmt_test.shared_fact; DROP TABLE bmt_test.shared_customer; DROP TABLE bmt_test.shared_product;
  " >/dev/null 2>&1
sleep 5
kubectl -n starrocks delete pod cleanup-mpp --ignore-not-found >/dev/null 2>&1

echo "완료. 위 타임스탬프에서 각 t_*_start/t_*_end 차이를 계산해 비교할 것."
