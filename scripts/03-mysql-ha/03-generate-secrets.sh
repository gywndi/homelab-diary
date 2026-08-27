#!/bin/bash
# 복제 계정 비밀번호 / keepalived VRRP 인증키를 생성해서 양쪽 서버의
# 전용 시크릿 디렉터리에 배포한다. 이 스크립트는 서버가 아니라 관리 머신(로컬)에서
# 실행한다. 값 자체는 어디에도 커밋되지 않고, 각 서버의 /etc/homelab-secrets/ 하위
# 파일에만 남는다 (root 전용 디렉터리로 별도 분리 — root의 홈 디렉터리와 섞지 않음).
#
# 사용법: ./03-generate-secrets.sh  (로컬에서 실행, ssh chan@10.5.5.8/.9 사전 인증 필요)

set -euo pipefail

HOSTS=(10.5.5.8 10.5.5.9)
SECRET_DIR="/etc/homelab-secrets"

REPL_PASS=$(openssl rand -base64 24)
VRRP_PASS=$(openssl rand -hex 4)   # keepalived auth_pass는 8자 제한

for h in "${HOSTS[@]}"; do
  echo "== $h 에 시크릿 배포 =="
  ssh -o BatchMode=yes "$h" "sudo bash -c '
    mkdir -p $SECRET_DIR
    chmod 700 $SECRET_DIR
    chown root:root $SECRET_DIR
    umask 077
    echo \"$REPL_PASS\" > $SECRET_DIR/mysql_repl_password
    echo \"$VRRP_PASS\" > $SECRET_DIR/keepalived_vrrp_pass
    chmod 600 $SECRET_DIR/mysql_repl_password $SECRET_DIR/keepalived_vrrp_pass
  '"
done

echo "완료: 시크릿 생성 및 배포 (양쪽 ${SECRET_DIR}/mysql_repl_password, ${SECRET_DIR}/keepalived_vrrp_pass)"
