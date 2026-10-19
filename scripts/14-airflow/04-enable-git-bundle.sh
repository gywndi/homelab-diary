#!/bin/bash
# Airflow 가 GitLab airflow-dags 저장소(main)를 DAG 소스로 쓰게 한다.
# 필요한 것: GitLab 프로젝트 chan/airflow-dags > Settings > Repository > Deploy tokens 에서
#   scope 'read_repository' 만 준 토큰을 만들고, 그 사용자명/토큰을 아래에서 입력한다(화면에 표시되지 않는다).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

read -r -p "deploy token 사용자명: " TUSER
read -r -s -p "deploy token 값: " TTOKEN; echo
[[ -n "$TUSER" && -n "$TTOKEN" ]] || { echo "비어 있다." >&2; exit 1; }

CONN=$(TUSER="$TUSER" TTOKEN="$TTOKEN" python3 -I -c "
import os, json
print(json.dumps({'conn_type': 'git', 'host': 'https://git.chan.io.kr/chan/airflow-dags.git',
                  'login': os.environ['TUSER'], 'password': os.environ['TTOKEN']}))")
kubectl -n airflow create secret generic airflow-git --from-literal=conn="$CONN" --dry-run=client -o yaml | kubectl apply -f -

# 번들 설정이 들어간 Deployment 를 적용한다(도메인 인자 없이 → ingress 는 건드리지 않음)
"$HERE/02-deploy-airflow.sh"
