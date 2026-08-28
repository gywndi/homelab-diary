#!/bin/bash
# 진짜 shared-nothing(starrocks-sn, 로컬 XFS) vs 진짜 shared-data(starrocks, RGW)
# CRUD 성능 재비교. 05-crud-benchmark.sh와 동일한 방법론(SELECT NOW(6)로 서버 사이드
# 시간만 측정)이지만, 이번엔 서로 다른 run_mode를 가진 완전히 별도의 FE 클러스터를
# 대상으로 한다 — 05번은 같은 shared_data FE 안에서 BE/CN을 나눴는데, 그 BE 테이블도
# 실제로는 cloud-native였다는 게 뒤늦게 밝혀졌기 때문(work/starrocks-architecture.md 참고).
#
# 사전 조건: 09-deploy-sn-fe.sh, 10-deploy-sn-be.sh(3노드) 실행 완료
# 사용법: ./12-real-sn-vs-shared-data-crud.sh

set -euo pipefail

ROWS=300000
UPDATE_DELETE_ROWS=30000

run_crud() {
  local ns="$1"
  local fe_host="$2"
  local table="$3"
  local ddl_properties="$4"
  local pod_slug="${table//_/-}"

  kubectl -n "$ns" delete pod "crud-setup-${pod_slug}" --ignore-not-found >/dev/null 2>&1
  kubectl -n "$ns" run "crud-setup-${pod_slug}" --restart=Never --image=mysql:8.0.46 -- \
    mysql -h "$fe_host" -P 9030 -u root -e "
      CREATE DATABASE IF NOT EXISTS bmt_test;
      USE bmt_test;
      CREATE TABLE IF NOT EXISTS ${table} (id BIGINT, category INT, value DOUBLE, ts DATETIME)
      PRIMARY KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 8 ${ddl_properties};
    " >/dev/null 2>&1

  until [ "$(kubectl -n "$ns" get pod "crud-setup-${pod_slug}" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Running" ] \
     && [ "$(kubectl -n "$ns" get pod "crud-setup-${pod_slug}" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Pending" ]; do
    sleep 5
  done
  kubectl -n "$ns" delete pod "crud-setup-${pod_slug}" --ignore-not-found >/dev/null 2>&1

  echo "== ${ns}/${table} CRUD 벤치마크 =="
  kubectl -n "$ns" delete pod "crud-bench-${pod_slug}" --ignore-not-found >/dev/null 2>&1
  kubectl -n "$ns" run "crud-bench-${pod_slug}" --restart=Never --image=mysql:8.0.46 -- \
    mysql -h "$fe_host" -P 9030 -u root -e "
      SELECT NOW(6) AS t_insert_start;
      INSERT INTO bmt_test.${table}
      SELECT id, id % 100, RAND()*1000, DATE_ADD('2026-01-01 00:00:00', INTERVAL id SECOND)
      FROM TABLE(generate_series(1, ${ROWS})) AS t(id);
      SELECT NOW(6) AS t_insert_end;
      SELECT NOW(6) AS t_point_start;
      SELECT * FROM bmt_test.${table} WHERE id = ${ROWS}/2;
      SELECT NOW(6) AS t_point_end;
      SELECT NOW(6) AS t_agg_start;
      SELECT category, COUNT(*), AVG(value) FROM bmt_test.${table} GROUP BY category ORDER BY category LIMIT 5;
      SELECT NOW(6) AS t_agg_end;
      SELECT NOW(6) AS t_update_start;
      INSERT INTO bmt_test.${table}
      SELECT id, category, value*2, ts FROM bmt_test.${table} WHERE id BETWEEN 1 AND ${UPDATE_DELETE_ROWS};
      SELECT NOW(6) AS t_update_end;
      SELECT NOW(6) AS t_delete_start;
      DELETE FROM bmt_test.${table} WHERE id BETWEEN $((ROWS - UPDATE_DELETE_ROWS + 1)) AND ${ROWS};
      SELECT NOW(6) AS t_delete_end;
      SELECT COUNT(*) AS final_count FROM bmt_test.${table};
    " >/dev/null 2>&1

  until [ "$(kubectl -n "$ns" get pod "crud-bench-${pod_slug}" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Running" ] \
     && [ "$(kubectl -n "$ns" get pod "crud-bench-${pod_slug}" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Pending" ]; do
    sleep 5
  done
  kubectl -n "$ns" logs "crud-bench-${pod_slug}"
  kubectl -n "$ns" delete pod "crud-bench-${pod_slug}" --ignore-not-found >/dev/null 2>&1
}

run_crud starrocks-sn fe.starrocks-sn.svc.cluster.local real_crud_local 'PROPERTIES("replication_num"="2")'
run_crud starrocks fe.starrocks.svc.cluster.local real_crud_shared ""

echo "== 정리 =="
kubectl -n starrocks-sn run cleanup-crud-sn --restart=Never --image=mysql:8.0.46 -- \
  mysql -h fe.starrocks-sn.svc.cluster.local -P 9030 -u root -e "DROP TABLE bmt_test.real_crud_local;" >/dev/null 2>&1
kubectl -n starrocks run cleanup-crud-sd --restart=Never --image=mysql:8.0.46 -- \
  mysql -h fe.starrocks.svc.cluster.local -P 9030 -u root -e "DROP TABLE bmt_test.real_crud_shared;" >/dev/null 2>&1
sleep 8
kubectl -n starrocks-sn delete pod cleanup-crud-sn --ignore-not-found >/dev/null 2>&1
kubectl -n starrocks delete pod cleanup-crud-sd --ignore-not-found >/dev/null 2>&1
