# Ceph 어플리케이션 샘플

> 이 문서는 초안이다. 검증까지 끝나면 `lessons/`로 옮겨 다듬는다. 아래 코드는 실제로 RGW에 연결해 실행·검증했다.

Ceph를 애플리케이션에서 직접 쓰는 방법은 두 가지다 — **RBD(블록)**는 보통 애플리케이션이 직접 API를 호출하지 않고 k8s CSI/libvirt가 대신 처리하므로(MySQL이 RBD PVC를 그냥 일반 디스크처럼 쓰는 것처럼), 애플리케이션 코드가 직접 다루는 건 대개 **RGW(S3 API)** 쪽이다. 아래는 Python `boto3`로 RGW에 접속해 버킷 생성 → 오브젝트 업로드/조회 → 삭제까지 하는 최소 예시다.

## 사전 준비

```bash
pip install boto3
```

전용 유저/키를 먼저 만들어둔다(버킷 생성은 radosgw-admin이 아니라 S3 API로 해야 한다 — [사용 예시](ceph-query-examples.md) 참고):

```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- \
  radosgw-admin user create --uid=demo-app --display-name="Demo App" --rgw-realm=starrocks-store
```

출력의 `keys[0].access_key`/`secret_key`를 환경변수(`RGW_ACCESS_KEY`/`RGW_SECRET_KEY`)로 넘기거나 코드에 채워 넣는다.

## 코드

전체 파일: [`scripts/07-ceph-storage/app-sample.py`](../scripts/07-ceph-storage/app-sample.py)

```python
import os
import boto3

RGW_ENDPOINT = "http://10.5.5.6:7480"   # RGW VIP — internal/ip-inventory.md 확인
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
```

## 실행 결과 (실제 검증)

```
$ RGW_ACCESS_KEY=... RGW_SECRET_KEY=... python3 scripts/07-ceph-storage/app-sample.py
objects: ['reports/2026-08-28.json']
content: b'{"status": "ok", "count": 42}'
OK
```

## 실전에서 고려할 점

- **RGW VIP는 클러스터 안팎 어디서든 접근 가능하다.** MetalLB LoadBalancer로 노출되어 있어서 k8s 내부 전용이 아니다 — 위 테스트도 클러스터 밖(로컬 머신)에서 그대로 실행했다.
- **`region_name`은 아무 값이나 넣어도 되지만 빈 값은 안 된다.** boto3가 SigV4 서명에 region을 요구해서, RGW가 신경 쓰지 않는 값이라도 문자열을 채워야 한다(`"default"` 등).
- **버킷 생성은 idempotent하지 않다.** 이미 존재하는 버킷에 `create_bucket`을 다시 호출하면 에러가 난다(소유자가 다르면 `BucketAlreadyExists`, 같으면 `BucketAlreadyOwnedByYou`) — 재시도 로직에서 이 두 예외를 구분해서 처리할 것.
- **RBD를 애플리케이션이 직접 다뤄야 하는 경우**(드묾)는 `rbd` Python 바인딩(`pip install rados rbd`)이 있지만, 우리 구성에서는 k8s CSI가 PVC로 추상화해줘서 애플리케이션은 그냥 일반 파일시스템 경로로 쓴다 — MySQL/StarRocks 모두 이 패턴.
