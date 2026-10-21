#!/bin/bash
# Airflow 읽기 전용 사용자 viewer 의 비밀번호를 설정한다. 새 비밀번호는 화면에 표시하지 않고 입력받는다.
# Secret 의 viewer-password 를 갱신한 뒤 파드를 재시작하면, init 컨테이너가 새 값으로 비밀번호 파일을 만든다.
# viewer 사용자 자체는 02-deploy-airflow.sh 가 등록한다. 이 스크립트는 비밀번호만 넣는다.
set -euo pipefail

read -r -s -p "새 viewer 비밀번호: " PW; echo
read -r -s -p "한 번 더: " PW2; echo
if [[ "$PW" != "$PW2" ]]; then echo "비밀번호가 서로 다르다." >&2; exit 1; fi
# passwords.json 을 printf 로 만들기 때문에 JSON 을 깨는 문자는 거부한다
if [[ "$PW" == *'"'* || "$PW" == *'\'* ]]; then echo '비밀번호에 " 와 \ 는 쓸 수 없다.' >&2; exit 1; fi
if [[ ${#PW} -lt 12 ]]; then echo "경고: 12자 미만이다. 인터넷에 노출된 서비스라 짧은 비밀번호는 위험하다." >&2; fi

B64=$(printf '%s' "$PW" | base64)
kubectl -n airflow patch secret airflow-secrets --type merge -p "{\"data\":{\"viewer-password\":\"${B64}\"}}"
kubectl -n airflow rollout restart deploy/airflow
kubectl -n airflow rollout status deploy/airflow --timeout=600s
echo "변경 완료. 1~2분 뒤 새 비밀번호로 로그인한다."
