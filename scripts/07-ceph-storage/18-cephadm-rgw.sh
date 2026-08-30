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

echo "완료: RGW 3개 배치"
