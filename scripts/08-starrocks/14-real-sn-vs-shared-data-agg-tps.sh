#!/bin/bash
# 진짜 shared-nothing(starrocks-sn) vs 진짜 shared-data(starrocks) 소규모 그룹핑
# 쿼리(GROUP BY)의 TPS(초당 처리량)를 직렬·동시 두 가지 방식으로 비교한다.
# 12-real-sn-vs-shared-data-crud.sh는 집계 쿼리를 딱 1번만 측정해서 노이즈(콜드
# 스타트/워밍업 차이)에 취약했다 — 여기서는 같은 쿼리를 반복 실행해 평균 지연시간과
# QPS를 낸다. 직렬(단일 커넥션 연속 실행)과 동시(여러 커넥션 병렬 실행)는 서버가
# 다르게 반응할 수 있어 같은 테이블로 순서대로 둘 다 측정한다.
#
# 사전 조건: 09-deploy-sn-fe.sh, 10-deploy-sn-be.sh(3노드) 실행 완료
# 사용법: ./14-real-sn-vs-shared-data-agg-tps.sh [직렬 반복 횟수, 기본 200] [동시 커넥션 수, 기본 20] [커넥션당 반복 횟수, 기본 20]

set -euo pipefail

SERIAL_ITERATIONS="${1:-200}"
CONCURRENCY="${2:-20}"
ITERATIONS_PER_CONN="${3:-20}"
ROWS=300000

setup_table() {
  local ns="$1" fe_host="$2" table="$3" ddl_properties="$4" slug="$5"

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
}

run_serial() {
  local ns="$1" fe_host="$2" table="$3" slug="$4"

  echo "== ${ns}/${table}: 직렬 — 그룹핑 쿼리 ${SERIAL_ITERATIONS}회 연속 실행 =="
  local query="SELECT category, COUNT(*), AVG(value) FROM bmt_test.${table} GROUP BY category ORDER BY category LIMIT 5;"
  local sql="SELECT NOW(6) AS t_start;"
  for _ in $(seq 1 "$SERIAL_ITERATIONS"); do
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
  echo ">> ${ns}/${table} 직렬: t_start/t_end 차이를 ${SERIAL_ITERATIONS}로 나누면 평균 지연시간, ${SERIAL_ITERATIONS}/(초)가 QPS."
}

run_concurrent() {
  local ns="$1" fe_host="$2" table="$3" slug="$4"

  echo "== ${ns}/${table}: 동시 — 커넥션 ${CONCURRENCY}개 x 커넥션당 ${ITERATIONS_PER_CONN}회 =="
  kubectl -n "$ns" delete pod "ctps-bench-${slug}" --ignore-not-found >/dev/null 2>&1
  kubectl -n "$ns" run "ctps-bench-${slug}" --restart=Never --image=mysql:8.0.46 --command -- \
    bash -c "
      Q='SELECT category, COUNT(*), AVG(value) FROM bmt_test.${table} GROUP BY category ORDER BY category LIMIT 5;'
      T0=\$(date +%s.%N)
      for i in \$(seq 1 ${CONCURRENCY}); do
        ( for j in \$(seq 1 ${ITERATIONS_PER_CONN}); do
            mysql -h ${fe_host} -P 9030 -u root -e \"\$Q\" >/dev/null
          done ) &
      done
      wait
      T1=\$(date +%s.%N)
      TOTAL=\$((${CONCURRENCY} * ${ITERATIONS_PER_CONN}))
      echo \"t0=\$T0 t1=\$T1 total_queries=\$TOTAL\"
    " >/dev/null 2>&1
  until [ "$(kubectl -n "$ns" get pod "ctps-bench-${slug}" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Running" ] \
     && [ "$(kubectl -n "$ns" get pod "ctps-bench-${slug}" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Pending" ]; do
    sleep 3
  done
  local result
  result="$(kubectl -n "$ns" logs "ctps-bench-${slug}")"
  local t0 t1 total elapsed qps
  t0="$(echo "$result" | grep -oE 't0=[0-9.]+' | cut -d= -f2)"
  t1="$(echo "$result" | grep -oE 't1=[0-9.]+' | cut -d= -f2)"
  total="$(echo "$result" | grep -oE 'total_queries=[0-9]+' | cut -d= -f2)"
  elapsed="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}')"
  qps="$(awk -v t="$total" -v e="$elapsed" 'BEGIN{printf "%.1f", t/e}')"
  echo ">> ${ns}/${table} 동시: elapsed=${elapsed}s total=${total} QPS=${qps}"
  kubectl -n "$ns" delete pod "ctps-bench-${slug}" --ignore-not-found >/dev/null 2>&1
}

cleanup_table() {
  local ns="$1" fe_host="$2" table="$3" slug="cleanup-tps-${3}"
  kubectl -n "$ns" run "$slug" --restart=Never --image=mysql:8.0.46 -- \
    mysql -h "$fe_host" -P 9030 -u root -e "DROP TABLE bmt_test.${table};" >/dev/null 2>&1
  sleep 5
  kubectl -n "$ns" delete pod "$slug" --ignore-not-found >/dev/null 2>&1
}

run_all() {
  local ns="$1" fe_host="$2" table="$3" ddl_properties="$4" slug="${3//_/-}"
  setup_table "$ns" "$fe_host" "$table" "$ddl_properties" "$slug"
  run_serial "$ns" "$fe_host" "$table" "$slug"
  run_concurrent "$ns" "$fe_host" "$table" "$slug"
  cleanup_table "$ns" "$fe_host" "$table"
}

run_all starrocks-sn fe.starrocks-sn.svc.cluster.local tps_local 'PROPERTIES("replication_num"="2")'
run_all starrocks fe.starrocks.svc.cluster.local tps_shared ""

echo "완료: 직렬/동시 TPS 비교 끝"
