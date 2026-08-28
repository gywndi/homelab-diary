#!/bin/bash
# 진짜 shared-nothing(starrocks-sn) vs 진짜 shared-data(starrocks) 소규모 그룹핑
# 쿼리(GROUP BY)의 TPS(초당 처리량) 비교. 12-real-sn-vs-shared-data-crud.sh는
# 집계 쿼리를 딱 1번만 측정해서 노이즈(콜드 스타트/워밍업 차이)에 취약했다 —
# 여기서는 동일 쿼리를 N회 연속 실행해 평균 지연시간과 QPS를 낸다.
#
# 사전 조건: 09-deploy-sn-fe.sh, 10-deploy-sn-be.sh(3노드) 실행 완료
# 사용법: ./14-real-sn-vs-shared-data-agg-tps.sh [반복 횟수, 기본 200]

set -euo pipefail

ITERATIONS="${1:-200}"
ROWS=300000

run_tps() {
  local ns="$1"
  local fe_host="$2"
  local table="$3"
  local ddl_properties="$4"
  local slug="${table//_/-}"

  echo "== ${ns}/${table}: 테이블 생성 + ${ROWS}행 로드 =="
  kubectl -n "$ns" delete pod "tps-setup-${slug}" --ignore-not-found >/dev/null 2>&1
  kubectl -n "$ns" run "tps-setup-${slug}" --restart=Never --image=mysql:8.0.46 -- \
    mysql -h "$fe_host" -P 9030 -u root -e "
      CREATE DATABASE IF NOT EXISTS bmt_test;
      USE bmt_test;
      CREATE TABLE IF NOT EXISTS ${table} (id BIGINT, category INT, value DOUBLE, ts DATETIME)
      DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 8 ${ddl_properties};
      INSERT INTO ${table}
      SELECT id, id % 100, RAND()*1000, DATE_ADD('2026-01-01 00:00:00', INTERVAL id SECOND)
      FROM TABLE(generate_series(1, ${ROWS})) AS t(id);
    " >/dev/null 2>&1
  until [ "$(kubectl -n "$ns" get pod "tps-setup-${slug}" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Running" ] \
     && [ "$(kubectl -n "$ns" get pod "tps-setup-${slug}" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Pending" ]; do
    sleep 5
  done
  kubectl -n "$ns" delete pod "tps-setup-${slug}" --ignore-not-found >/dev/null 2>&1

  echo "== ${ns}/${table}: 그룹핑 쿼리 ${ITERATIONS}회 연속 실행 =="
  local query="SELECT category, COUNT(*), AVG(value) FROM bmt_test.${table} GROUP BY category ORDER BY category LIMIT 5;"
  local sql="SELECT NOW(6) AS t_start;"
  for _ in $(seq 1 "$ITERATIONS"); do
    sql="${sql}${query}"
  done
  sql="${sql}SELECT NOW(6) AS t_end;"

  kubectl -n "$ns" delete pod "tps-bench-${slug}" --ignore-not-found >/dev/null 2>&1
  kubectl -n "$ns" run "tps-bench-${slug}" --restart=Never --image=mysql:8.0.46 -- \
    mysql -h "$fe_host" -P 9030 -u root -e "$sql" >/dev/null 2>&1
  until [ "$(kubectl -n "$ns" get pod "tps-bench-${slug}" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Running" ] \
     && [ "$(kubectl -n "$ns" get pod "tps-bench-${slug}" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Pending" ]; do
    sleep 3
  done
  kubectl -n "$ns" logs "tps-bench-${slug}" | grep -A1 "t_start\|t_end"
  kubectl -n "$ns" delete pod "tps-bench-${slug}" --ignore-not-found >/dev/null 2>&1
}

run_tps starrocks-sn fe.starrocks-sn.svc.cluster.local tps_local 'PROPERTIES("replication_num"="2")'
run_tps starrocks fe.starrocks.svc.cluster.local tps_shared ""

echo "== 정리 =="
kubectl -n starrocks-sn run cleanup-tps-sn --restart=Never --image=mysql:8.0.46 -- \
  mysql -h fe.starrocks-sn.svc.cluster.local -P 9030 -u root -e "DROP TABLE bmt_test.tps_local;" >/dev/null 2>&1
kubectl -n starrocks run cleanup-tps-sd --restart=Never --image=mysql:8.0.46 -- \
  mysql -h fe.starrocks.svc.cluster.local -P 9030 -u root -e "DROP TABLE bmt_test.tps_shared;" >/dev/null 2>&1
sleep 8
kubectl -n starrocks-sn delete pod cleanup-tps-sn --ignore-not-found >/dev/null 2>&1
kubectl -n starrocks delete pod cleanup-tps-sd --ignore-not-found >/dev/null 2>&1

echo "완료. t_start/t_end 차이를 ${ITERATIONS}로 나누면 평균 지연시간, ${ITERATIONS}/(초)가 QPS."
