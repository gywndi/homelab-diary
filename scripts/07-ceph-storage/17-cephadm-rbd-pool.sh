#!/bin/bash
# RBD(블록) 풀 생성. MySQL/KVM이 여기서 나온 이미지를 쓴다.
#
# 사전 조건: OSD가 최소 3개 이상 up 상태일 것(16-cephadm-add-osd.sh 완료)
# 사용법: chan08에서 실행
#   sudo ./17-cephadm-rbd-pool.sh

set -euo pipefail

echo "== rbd-pool 생성(32 PG) =="
cephadm shell -- ceph osd pool create rbd-pool 32 32 replicated

echo "== 3-replica(size=3/min_size=2) 설정 =="
cephadm shell -- ceph osd pool set rbd-pool size 3
cephadm shell -- ceph osd pool set rbd-pool min_size 2

echo "== RBD 용도로 초기화 =="
cephadm shell -- rbd pool init rbd-pool
cephadm shell -- ceph osd pool application enable rbd-pool rbd

echo "완료: rbd-pool 준비됨"
