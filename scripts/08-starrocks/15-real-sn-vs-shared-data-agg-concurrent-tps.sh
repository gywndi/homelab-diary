#!/bin/bash
# 진짜 shared-nothing(starrocks-sn) vs 진짜 shared-data(starrocks) 소규모 그룹핑
# 쿼리의 "동시 처리" TPS 비교. 14번 스크립트는 단일 커넥션 직렬 실행이라 서버가
# 동시 요청을 얼마나 잘 흡수하는지는 안 보여준다 — 여기서는 한 파드 안에서
# mysql 클라이언트 프로세스 C개를 동시에 띄우고, 각자 N회씩 반복 실행해서
# 전체 벽시계 시간 기준 합산 QPS(동시 처리량)를 낸다.
#
# 사전 조건: 09-deploy-sn-fe.sh, 10-deploy-sn-be.sh(3노드) 실행 완료
# 사용법: ./15-real-sn-vs-shared-data-agg-concurrent-tps.sh [동시 커넥션 수, 기본 20] [커넥션당 반복 횟수, 기본 20]

set -euo pipefail

CONCURRENCY="${1:-20}"
ITERATIONS_PER_CONN="${2:-20}"
ROWS=300000

run_concurrent() {
  local ns="$1"
  local fe_host="$2"
  local table="$3"
  local ddl_properties="$4"
  local slug="${table//_/-}"

  echo "== ${ns}/${table}: 테이블 생성 + ${ROWS}행 로드 =="
  kubectl -n "$ns" delete pod "ctps-setup-${slug}" --ignore-not-found >/dev/null 2>&1
  kubectl -n "$ns" run "ctps-setup-${slug}" --restart=Never --image=mysql:8.0.46 -- \
    mysql -h "$fe_host" -P 9030 -u root -e "
      CREATE DATABASE IF NOT EXISTS bmt_test;
      USE bmt_test;
      CREATE TABLE IF NOT EXISTS ${table} (id BIGINT, category INT, value DOUBLE, ts DATETIME)
      DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 8 ${ddl_properties};
      INSERT INTO ${table}
      SELECT id, id % 100, RAND()*1000, DATE_ADD('2026-01-01 00:00:00', INTERVAL id SECOND)
      FROM TABLE(generate_series(1, ${ROWS})) AS t(id);
    " >/dev/null 2>&1
  until [ "$(kubectl -n "$ns" get pod "ctps-setup-${slug}" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Running" ] \
     && [ "$(kubectl -n "$ns" get pod "ctps-setup-${slug}" -o jsonpath='{.status.phase}' 2>/dev/null)" != "Pending" ]; do
    sleep 5
  done
  kubectl -n "$ns" delete pod "ctps-setup-${slug}" --ignore-not-found >/dev/null 2>&1

  echo "== ${ns}/${table}: 동시 커넥션 ${CONCURRENCY}개 x 커넥션당 ${ITERATIONS_PER_CONN}회 =="
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
  echo "$result"
  local t0 t1 total elapsed qps
  t0="$(echo "$result" | grep -oE 't0=[0-9.]+' | cut -d= -f2)"
  t1="$(echo "$result" | grep -oE 't1=[0-9.]+' | cut -d= -f2)"
  total="$(echo "$result" | grep -oE 'total_queries=[0-9]+' | cut -d= -f2)"
  elapsed="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}')"
  qps="$(awk -v t="$total" -v e="$elapsed" 'BEGIN{printf "%.1f", t/e}')"
  echo ">> ${ns}/${table}: elapsed=${elapsed}s total=${total} QPS=${qps}"
  kubectl -n "$ns" delete pod "ctps-bench-${slug}" --ignore-not-found >/dev/null 2>&1
}

run_concurrent starrocks-sn fe.starrocks-sn.svc.cluster.local ctps_local 'PROPERTIES("replication_num"="2")'
run_concurrent starrocks fe.starrocks.svc.cluster.local ctps_shared ""

echo "== 정리 =="
kubectl -n starrocks-sn run cleanup-ctps-sn --restart=Never --image=mysql:8.0.46 -- \
  mysql -h fe.starrocks-sn.svc.cluster.local -P 9030 -u root -e "DROP TABLE bmt_test.ctps_local;" >/dev/null 2>&1
kubectl -n starrocks run cleanup-ctps-sd --restart=Never --image=mysql:8.0.46 -- \
  mysql -h fe.starrocks.svc.cluster.local -P 9030 -u root -e "DROP TABLE bmt_test.ctps_shared;" >/dev/null 2>&1
sleep 8
kubectl -n starrocks-sn delete pod cleanup-ctps-sn --ignore-not-found >/dev/null 2>&1
kubectl -n starrocks delete pod cleanup-ctps-sd --ignore-not-found >/dev/null 2>&1

echo "완료."
