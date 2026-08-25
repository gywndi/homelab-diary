#!/bin/bash
# 복제 계정 비밀번호 / keepalived VRRP 인증키를 생성해서 양쪽 서버의
# root-only 파일에 배포한다. 이 스크립트는 서버가 아니라 관리 머신(로컬)에서
# 실행한다. 값 자체는 어디에도 커밋되지 않고, 각 서버의 /root/ 하위 파일에만 남는다.
#
# 사용법: ./03-generate-secrets.sh  (로컬에서 실행, ssh chan@10.5.5.8/.9 사전 인증 필요)

set -euo pipefail

HOSTS=(10.5.5.8 10.5.5.9)

REPL_PASS=$(openssl rand -base64 24)
VRRP_PASS=$(openssl rand -hex 4)   # keepalived auth_pass는 8자 제한

for h in "${HOSTS[@]}"; do
  echo "== $h 에 시크릿 배포 =="
  ssh -o BatchMode=yes "$h" "sudo bash -c '
    umask 077
    echo \"$REPL_PASS\" > /root/.mysql_repl_password
    echo \"$VRRP_PASS\" > /root/.keepalived_vrrp_pass
    chmod 600 /root/.mysql_repl_password /root/.keepalived_vrrp_pass
  '"
done

echo "완료: 시크릿 생성 및 배포 (양쪽 /root/.mysql_repl_password, /root/.keepalived_vrrp_pass)"
