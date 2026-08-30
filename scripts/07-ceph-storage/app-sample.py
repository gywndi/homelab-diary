#!/usr/bin/env python3
"""Ceph RGW(S3 API) 어플리케이션 샘플 — boto3로 접속해 버킷/오브젝트 업로드·조회·삭제하는
최소 예시.

사전 조건: pip install boto3
           전용 유저/키를 먼저 만들어둘 것 (radosgw-admin은 유저만 만들고 버킷 생성은
           S3 API로 해야 한다 — scripts/08-starrocks/00-create-rgw-user-and-bucket.sh 참고):
             sudo cephadm shell -- radosgw-admin user create --uid=<uid> --display-name="<name>"
           출력의 keys[0].access_key / secret_key를 아래 자리에 채워 넣거나 환경변수로 분리할 것.

RGW_ENDPOINT는 도메인(ceph.home)으로, 클러스터 안팎 어디서든 접근 가능하다
(keepalived VIP로 노출되어 있음 — k8s 내부 전용이 아님. VIP 자체는
internal/ip-inventory.md 확인).
"""
import os
import boto3

RGW_ENDPOINT = "http://ceph.home:7480"
ACCESS_KEY = os.environ.get("RGW_ACCESS_KEY", "<access_key>")
SECRET_KEY = os.environ.get("RGW_SECRET_KEY", "<secret_key>")
BUCKET = "demo-app-bucket"

s3 = boto3.client(
    "s3",
    endpoint_url=RGW_ENDPOINT,
    aws_access_key_id=ACCESS_KEY,
    aws_secret_access_key=SECRET_KEY,
    region_name="default",
)

s3.create_bucket(Bucket=BUCKET)

s3.put_object(Bucket=BUCKET, Key="reports/2026-08-28.json", Body=b'{"status": "ok", "count": 42}')

resp = s3.list_objects_v2(Bucket=BUCKET)
print("objects:", [o["Key"] for o in resp.get("Contents", [])])

obj = s3.get_object(Bucket=BUCKET, Key="reports/2026-08-28.json")
print("content:", obj["Body"].read())

s3.delete_object(Bucket=BUCKET, Key="reports/2026-08-28.json")
s3.delete_bucket(Bucket=BUCKET)
print("OK")
