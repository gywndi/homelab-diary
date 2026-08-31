#!/bin/bash
# erasure coding(EC) 풀 생성 — 참고용. 지금 운영 중인 풀(rbd-pool,
# default.rgw.buckets.data)에는 적용돼 있지 않다.
#
# 실측 결과는 lessons/07-2-ceph-storage-bmt.md 참고: 순차 I/O는 같은 장애
# 허용 기준으로 replicated와 큰 차이 없지만(쓰기 +6.5%/읽기 -24%), RBD
# 랜덤 소규모 쓰기는 18배 느려서 rbd-pool(MySQL/KVM)에는 안 맞는다.
# RGW(buckets.data) 전환은 저장 공간 절약이 실이득이라 검토할 만하지만,
# 이미 운영 중인 realm의 데이터 풀 교체는 이 스크립트 범위 밖이다
# (기존 오브젝트 마이그레이션까지 별도 계획 필요).
#
# 사용법: chan08에서 실행
#   sudo ./21-cephadm-ec-pool-example.sh <풀 이름> <k> <m>
#   예: sudo ./21-cephadm-ec-pool-example.sh test-ec-rbd 2 1

set -euo pipefail

POOL="${1:-}"
K="${2:-}"
M="${3:-}"
if [[ -z "$POOL" || -z "$K" || -z "$M" ]]; then
  echo "사용법: $0 <풀 이름> <k> <m>" >&2
  exit 1
fi

PROFILE="${POOL}-ec-profile"

echo "== EC 프로필 생성 (장애 도메인은 host — OSD 개수가 아니라 노드 개수가 k+m의 상한) =="
cephadm shell -- ceph osd erasure-code-profile set "$PROFILE" k="$K" m="$M" crush-failure-domain=host

echo "== EC 풀 생성 =="
cephadm shell -- ceph osd pool create "$POOL" erasure "$PROFILE"
cephadm shell -- ceph osd pool application enable "$POOL" rbd

cat <<EOF

완료: ${POOL} (k=${K}, m=${M}) 생성됨.

RGW(buckets.data)로 쓸 경우 이대로 zone placement target에 연결하면 된다.

RBD로 쓸 경우 추가로 필요 (EC 풀은 부분 덮어쓰기를 기본 지원하지 않음):
  cephadm shell -- ceph osd pool set ${POOL} allow_ec_overwrites true
  cephadm shell -- ceph osd pool create ${POOL}-meta 1 1 replicated
  cephadm shell -- rbd pool init ${POOL}-meta
  cephadm shell -- rbd create --size <크기> --data-pool ${POOL} ${POOL}-meta/<이미지 이름>
EOF
