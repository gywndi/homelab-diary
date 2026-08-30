#!/bin/bash
# RGW에 StarRocks 전용 유저 생성 + 버킷 생성, 자격증명을 k8s Secret으로 저장.
# radosgw-admin은 cephadm shell로 실행하므로 Ceph 클러스터 호스트(chan08)에서 실행해야 하고,
# 이 스크립트의 kubectl 부분(Secret 저장)은 k8s 접근 가능한 곳이면 어디서든 된다.
#
# 사용법: chan08에서 실행 (cephadm이 설치된 호스트)
#   ./00-create-rgw-user-and-bucket.sh

set -euo pipefail

BUCKET="starrocks-storage"
RGW_ENDPOINT_HOST="ceph.home"   # RGW VIP(ceph.home) — internal/ip-inventory.md 확인
RGW_ENDPOINT_PORT="7480"

echo "== RGW 유저 생성 (이미 있으면 기존 키 재사용) =="
USER_JSON=$(sudo cephadm shell -- radosgw-admin user create \
  --uid=starrocks --display-name="StarRocks" 2>/dev/null \
  || sudo cephadm shell -- radosgw-admin user info --uid=starrocks)

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

echo "== k8s Secret 저장 =="
kubectl create namespace starrocks --dry-run=client -o yaml | kubectl apply -f -
kubectl -n starrocks create secret generic rgw-credentials \
  --from-literal=access_key="$ACCESS_KEY" \
  --from-literal=secret_key="$SECRET_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "완료: RGW 유저/버킷 준비, starrocks 네임스페이스에 rgw-credentials Secret 저장됨"
