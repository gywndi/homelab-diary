#!/bin/bash
# End-to-end 검증: DB/테이블 생성 + INSERT + SELECT로 RGW까지 실제 데이터가
# 쓰이는지 확인한다. 첫 테이블 생성은 콜드 스타트로 60~300초 걸릴 수 있다
# (README.md 참고) — 조급하게 타임아웃 낮추지 말 것.
#
# 사용법: ./03-verify.sh

set -euo pipefail

kubectl -n starrocks run mysql-client-verify --rm -i --restart=Never --image=mysql:8.0.46 -- \
  mysql -h fe.starrocks.svc.cluster.local -P 9030 -u root -e '
CREATE DATABASE IF NOT EXISTS bmt_test;
USE bmt_test;
CREATE TABLE IF NOT EXISTS t1 (id INT, name VARCHAR(50)) DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 4 PROPERTIES("replication_num"="1");
INSERT INTO t1 VALUES (1,"hello"),(2,"starrocks"),(3,"ceph");
SELECT * FROM t1 ORDER BY id;
'

echo "완료: bmt_test.t1 테이블 생성/조회 성공. RGW 버킷 오브젝트 수 증가 여부는 아래로 확인 가능:"
echo "  kubectl -n rook-ceph exec deploy/rook-ceph-tools -- radosgw-admin bucket stats --bucket=starrocks-storage --rgw-realm=starrocks-store"
