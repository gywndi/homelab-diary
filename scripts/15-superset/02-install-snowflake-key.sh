#!/bin/bash
# Airflow 커넥션 snowflake_app 의 개인키를 PEM 파일로 만들어 Superset 파드의 PVC 에 둔다.
# 키는 두 파드 사이로 바로 전달하며 화면과 로컬 디스크에 남기지 않는다.
# Superset 의 Secure Extra 는 이 경로를 가리킨다: {"auth_method":"keypair","auth_params":{"privatekey_path":"/app/superset_home/snowflake_key.pem"}}
set -euo pipefail

AIRFLOW_POD=$(kubectl -n airflow get pod -l app=airflow -o name | head -1)
SUPERSET_POD=$(kubectl -n superset get pod -l app=superset -o name | head -1)

# Airflow 에 저장된 키(base64 PEM)를 꺼내 헤더/푸터를 맞추고 64자 단위로 줄바꿈한 PEM 으로 출력한다
kubectl -n airflow exec -i "$AIRFLOW_POD" -c airflow -- python - <<'PY' |
import json, base64, re, subprocess, textwrap
d = json.loads(subprocess.run(["airflow", "connections", "get", "snowflake_app", "-o", "json"], capture_output=True, text=True).stdout)
d = d[0] if isinstance(d, list) else d
pk = d["extra_dejson"]["private_key_content"]
raw = base64.b64decode(pk).decode() if not pk.startswith("-----") else pk
body = re.sub(r"-----[A-Z ]+-----|\s", "", raw)
print("-----BEGIN PRIVATE KEY-----\n" + "\n".join(textwrap.wrap(body, 64)) + "\n-----END PRIVATE KEY-----")
PY
  kubectl -n superset exec -i "$SUPERSET_POD" -- bash -c 'umask 077; cat > /app/superset_home/snowflake_key.pem'

# 파일이 유효한 개인키인지, 공개키 지문이 Snowflake 에 등록된 값과 같은지 확인한다
kubectl -n superset exec "$SUPERSET_POD" -- bash -c 'ls -l /app/superset_home/snowflake_key.pem; openssl pkey -in /app/superset_home/snowflake_key.pem -pubout -outform DER | openssl dgst -sha256 -binary | base64 | sed "s/^/SHA256:/"'
