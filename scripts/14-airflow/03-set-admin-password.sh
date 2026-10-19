#!/bin/bash
# Airflow admin 비밀번호를 바꾼다. 새 비밀번호는 화면에 표시하지 않고 입력받는다.
# Secret 의 admin-password 를 갱신한 뒤 파드를 재시작하면, init 컨테이너가 새 값으로 비밀번호 파일을 만든다.
set -euo pipefail

read -r -s -p "새 admin 비밀번호: " PW; echo
read -r -s -p "한 번 더: " PW2; echo
if [[ "$PW" != "$PW2" ]]; then echo "비밀번호가 서로 다르다." >&2; exit 1; fi
if [[ ${#PW} -lt 12 ]]; then echo "12자 이상으로 정한다(인터넷에 노출된 서비스)." >&2; exit 1; fi

B64=$(printf '%s' "$PW" | base64)
kubectl -n airflow patch secret airflow-secrets --type merge -p "{\"data\":{\"admin-password\":\"${B64}\"}}"
kubectl -n airflow rollout restart deploy/airflow
kubectl -n airflow rollout status deploy/airflow --timeout=600s
echo "변경 완료. 1~2분 뒤 새 비밀번호로 로그인한다."
