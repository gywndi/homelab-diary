#!/bin/bash
# shared-nothing(BE) vs shared-data(CN) 대용량 로드 비교 — 고카디널리티 버전.
# 06-mpp-benchmark.sh의 저카디널리티(id % N 패턴) 데이터는 컬럼 압축이 너무 잘 먹혀서
# 1GbE Ceph 쓰기 병목(rados bench 86MB/s)이 전혀 드러나지 않았다. 이 스크립트는
# 행마다 MD5 해시 8개를 이어붙인 ~256바이트짜리 사실상 무작위 payload 컬럼을 추가해서
# 컬럼 압축 효율을 의도적으로 낮추고, 실제 병목이 보이는지 확인한다.
#
# 사전 조건: scripts/08-starrocks/06-mpp-benchmark.sh와 동일(BE/CN 최소 1개씩 등록)
# 사용법: ./07-high-cardinality-benchmark.sh

set -euo pipefail

FE_HOST="fe.starrocks.svc.cluster.local"
ROWS=10000000

wait_pod() {
  local pod="$1"
  until [ "$(kubectl -n starrocks get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Running" ] \
     && [ "$(kubectl -n starrocks get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Pending" ]; do
    sleep 5
  done
}

run_hc() {
  local prefix="$1"
  local ddl_properties="$2"

  echo "== ${prefix}: 스키마 생성 =="
  kubectl -n starrocks delete pod "hc-schema-${prefix}" --ignore-not-found >/dev/null 2>&1
  kubectl -n starrocks run "hc-schema-${prefix}" --restart=Never --image=mysql:8.0.46 -- \
    mysql -h "$FE_HOST" -P 9030 -u root -e "
      USE bmt_test;
      CREATE TABLE IF NOT EXISTS hc_${prefix}_fact (id BIGINT, customer_id INT, product_id INT, quantity INT, ts DATETIME, payload VARCHAR(500))
      DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 16 ${ddl_properties};
    " >/dev/null 2>&1
  wait_pod "hc-schema-${prefix}"
  kubectl -n starrocks delete pod "hc-schema-${prefix}" --ignore-not-found >/dev/null 2>&1

  echo "== ${prefix}: 고카디널리티 로드 (${ROWS}행, 행당 ~256B 랜덤 payload) =="
  kubectl -n starrocks delete pod "hc-load-${prefix}" --ignore-not-found >/dev/null 2>&1
  kubectl -n starrocks run "hc-load-${prefix}" --restart=Never --image=mysql:8.0.46 -- \
    mysql -h "$FE_HOST" -P 9030 -u root -e "
      USE bmt_test;
      SELECT NOW(6) AS t_load_start;
      INSERT INTO hc_${prefix}_fact
      SELECT id,
        FLOOR(RAND()*100000)+1,
        FLOOR(RAND()*10000)+1,
        FLOOR(RAND()*10)+1,
        DATE_ADD('2026-01-01 00:00:00', INTERVAL id SECOND),
        CONCAT(MD5(CONCAT(id,RAND())), MD5(CONCAT(id,RAND())), MD5(CONCAT(id,RAND())), MD5(CONCAT(id,RAND())),
               MD5(CONCAT(id,RAND())), MD5(CONCAT(id,RAND())), MD5(CONCAT(id,RAND())), MD5(CONCAT(id,RAND())))
      FROM TABLE(generate_series(1, ${ROWS})) AS t(id);
      SELECT NOW(6) AS t_load_end;
    " >/dev/null 2>&1
  wait_pod "hc-load-${prefix}"
  kubectl -n starrocks logs "hc-load-${prefix}"
  kubectl -n starrocks delete pod "hc-load-${prefix}" --ignore-not-found >/dev/null 2>&1

  echo "== ${prefix}: 집계 쿼리 =="
  kubectl -n starrocks delete pod "hc-agg-${prefix}" --ignore-not-found >/dev/null 2>&1
  kubectl -n starrocks run "hc-agg-${prefix}" --restart=Never --image=mysql:8.0.46 -- \
    mysql -h "$FE_HOST" -P 9030 -u root -e "
      USE bmt_test;
      SELECT NOW(6) AS t_agg_start;
      SELECT COUNT(*), AVG(quantity), COUNT(DISTINCT customer_id) FROM hc_${prefix}_fact WHERE quantity > 5;
      SELECT NOW(6) AS t_agg_end;
    " >/dev/null 2>&1
  wait_pod "hc-agg-${prefix}"
  kubectl -n starrocks logs "hc-agg-${prefix}"
  kubectl -n starrocks delete pod "hc-agg-${prefix}" --ignore-not-found >/dev/null 2>&1
}

run_hc "local" 'PROPERTIES("replication_num"="2")'
run_hc "shared" ""

echo "== 정리 =="
kubectl -n starrocks delete pod cleanup-hc --ignore-not-found >/dev/null 2>&1
kubectl -n starrocks run cleanup-hc --restart=Never --image=mysql:8.0.46 -- \
  mysql -h "$FE_HOST" -P 9030 -u root -e "DROP TABLE bmt_test.hc_local_fact; DROP TABLE bmt_test.hc_shared_fact;" >/dev/null 2>&1
sleep 8
kubectl -n starrocks delete pod cleanup-hc --ignore-not-found >/dev/null 2>&1

echo "완료. 위 타임스탬프에서 각 t_*_start/t_*_end 차이를 계산해 비교할 것."
