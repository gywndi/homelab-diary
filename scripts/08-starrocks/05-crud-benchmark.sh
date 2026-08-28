#!/bin/bash
# shared-nothing(BE) vs shared-data(CN) CRUD 성능 비교 벤치마크.
# 동일한 Primary Key 테이블/데이터로 INSERT/SELECT(point+집계)/UPDATE(upsert)/DELETE를
# 순서대로 실행하고, SELECT NOW(6)으로 각 단계 전후를 감싸서 서버 사이드 시간만 측정한다
# (클라이언트 파드 기동 오버헤드를 배제하기 위함).
#
# 사전 조건:
#   - CN이 이미 FE에 등록되어 있을 것 (scripts/08-starrocks/02-deploy-cn.sh)
#   - BE가 최소 2개(replication_num=2를 만족하려면) 등록되어 있을 것
#     (scripts/08-starrocks/04-deploy-be-hybrid.sh를 노드별로 반복 실행)
#
# 사용법: ./05-crud-benchmark.sh
#   결과는 stdout에 각 단계 시작/종료 타임스탬프로 출력된다 — 직접 밀리초 차이를 계산할 것

set -euo pipefail

FE_HOST="fe.starrocks.svc.cluster.local"
ROWS=300000
UPDATE_DELETE_ROWS=30000

run_crud() {
  local table="$1"
  local ddl_properties="$2"

  kubectl -n starrocks delete pod "crud-setup-${table}" --ignore-not-found >/dev/null 2>&1
  kubectl -n starrocks run "crud-setup-${table}" --restart=Never --image=mysql:8.0.46 -- \
    mysql -h "$FE_HOST" -P 9030 -u root -e "
      USE bmt_test;
      CREATE TABLE IF NOT EXISTS ${table} (id BIGINT, category INT, value DOUBLE, ts DATETIME)
      PRIMARY KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 8 ${ddl_properties};
    " >/dev/null 2>&1

  # 테이블 생성은 클러스터/스토리지 종류당 최초 1회만 느리다(내부 _statistics_
  # 시스템 테이블들이 같이 생성되며 밀리기 때문) — 완료될 때까지 조급하게 죽이지 말 것.
  until [ "$(kubectl -n starrocks get pod "crud-setup-${table}" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Running" ] \
     && [ "$(kubectl -n starrocks get pod "crud-setup-${table}" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Pending" ]; do
    sleep 5
  done
  kubectl -n starrocks delete pod "crud-setup-${table}" --ignore-not-found >/dev/null 2>&1

  echo "== ${table} CRUD 벤치마크 =="
  kubectl -n starrocks delete pod "crud-bench-${table}" --ignore-not-found >/dev/null 2>&1
  kubectl -n starrocks run "crud-bench-${table}" --restart=Never --image=mysql:8.0.46 -- \
    mysql -h "$FE_HOST" -P 9030 -u root -e "
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

  until [ "$(kubectl -n starrocks get pod "crud-bench-${table}" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Running" ] \
     && [ "$(kubectl -n starrocks get pod "crud-bench-${table}" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Pending" ]; do
    sleep 5
  done
  kubectl -n starrocks logs "crud-bench-${table}"
  kubectl -n starrocks delete pod "crud-bench-${table}" --ignore-not-found >/dev/null 2>&1
}

run_crud "crud_local" 'PROPERTIES("replication_num"="2")'
run_crud "crud_shared" ""

echo "== 정리 =="
kubectl -n starrocks run cleanup-crud --restart=Never --image=mysql:8.0.46 -- \
  mysql -h "$FE_HOST" -P 9030 -u root -e "DROP TABLE bmt_test.crud_local; DROP TABLE bmt_test.crud_shared;" >/dev/null 2>&1
sleep 5
kubectl -n starrocks delete pod cleanup-crud --ignore-not-found >/dev/null 2>&1

echo "완료. 위 타임스탬프에서 각 t_*_start/t_*_end 차이를 계산해 비교할 것."
