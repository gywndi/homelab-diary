#!/bin/bash
# RGW(오브젝트, S3 API) 데몬을 3노드 전부에 배치한다.
#
# 사전 조건: 3노드 전부 15-cephadm-add-host.sh로 추가돼 있을 것
# 사용법: chan08에서 실행
#   sudo ./18-cephadm-rgw.sh

set -euo pipefail

echo "== RGW 데몬을 3노드에 배치 =="
cephadm shell -- ceph orch apply rgw starrocks-store --placement="chan08,chan09,llm001" --port=7480

echo "== 배치 확인(수 초 후 3개 다 running이어야 함) =="
sleep 15
cephadm shell -- ceph orch ps --daemon-type rgw

echo "== 데이터 풀 복제본 수를 2로 낮춤(연구용 데이터라 손실 감수, 쓰기 증폭 줄이기) =="
# ceph orch apply rgw가 데이터 풀(default.rgw.buckets.data)을 처음 만들 때 클러스터
# 기본값(3노드라 size=3)으로 생성한다 — 명시적으로 낮추지 않으면 계속 3으로 남는다.
# lessons/07-1-ceph-storage.md "남아있는 리스크" 참고.
until cephadm shell -- ceph osd pool ls | grep -q '^default.rgw.buckets.data$'; do sleep 5; done
cephadm shell -- ceph osd pool set default.rgw.buckets.data size 2
cephadm shell -- ceph osd pool set default.rgw.buckets.data min_size 1

echo "완료: RGW 3개 배치, 데이터 풀 size=2/min_size=1"
