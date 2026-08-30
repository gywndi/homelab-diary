#!/bin/bash
# 베어메탈 shared-data 클러스터(07/08번 스크립트) 전용 RGW 유저 생성 + 버킷 생성.
# 원리는 00-create-rgw-user-and-bucket.sh와 같지만, 저장할 곳이 k8s Secret이 아니라
# fe.conf에 직접 넣을 값이라 화면에 그대로 출력하고 넘긴다.
#
# 사용법: chan08에서 실행 (cephadm이 설치된 호스트)
#   ./06-create-shared-data-rgw-user-and-bucket.sh

set -euo pipefail

BUCKET="baremetal-starrocks-storage"
RGW_UID="baremetal-starrocks"
RGW_ENDPOINT_HOST="ceph.home"
RGW_ENDPOINT_PORT="7480"

echo "== RGW 유저 생성 (이미 있으면 기존 키 재사용) =="
USER_JSON=$(sudo cephadm shell -- radosgw-admin user create \
  --uid="$RGW_UID" --display-name="Baremetal StarRocks" 2>/dev/null \
  || sudo cephadm shell -- radosgw-admin user info --uid="$RGW_UID")

# cephadm shell이 JSON 앞에 "Inferring config..." 같은 배너 줄을 섞어 출력하므로,
# 첫 '{' 부터만 잘라내 파싱한다.
ACCESS_KEY=$(echo "$USER_JSON" | python3 -c "import json,sys; d=sys.stdin.read(); print(json.loads(d[d.index('{'):])['keys'][0]['access_key'])")
SECRET_KEY=$(echo "$USER_JSON" | python3 -c "import json,sys; d=sys.stdin.read(); print(json.loads(d[d.index('{'):])['keys'][0]['secret_key'])")

echo "== 버킷 생성 (AWS SigV2 수동 서명 PUT — radosgw-admin은 버킷 생성을 지원하지 않음) =="
DATE=$(date -R)
STRING_TO_SIGN="PUT\n\n\n${DATE}\n/${BUCKET}/"
SIG=$(printf "%b" "$STRING_TO_SIGN" | openssl dgst -sha1 -hmac "$SECRET_KEY" -binary | base64)
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
  -H "Date: ${DATE}" \
  -H "Authorization: AWS ${ACCESS_KEY}:${SIG}" \
  "http://${RGW_ENDPOINT_HOST}:${RGW_ENDPOINT_PORT}/${BUCKET}/")
echo "버킷 생성 응답: ${HTTP_CODE}"

echo "완료: ACCESS_KEY=${ACCESS_KEY} SECRET_KEY=${SECRET_KEY}"
echo "다음 단계(07-install-shared-data-fe.sh)에 이 두 값을 그대로 인자로 넘길 것"
