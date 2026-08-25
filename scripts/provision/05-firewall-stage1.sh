#!/bin/bash
# Stage 1 방화벽 재정리: MySQL/keepalived 포트 추가, 미사용 Calico 포트 제거
#
# 사용법: sudo ./05-firewall-stage1.sh

set -euo pipefail

SUBNET="10.5.5.0/24"

echo "== MySQL 포트 추가 =="
ufw allow from "$SUBNET" to any port 3306 proto tcp comment 'MySQL'

echo "== keepalived VRRP 허용 =="
ufw allow from "$SUBNET" proto vrrp comment 'keepalived VRRP'

echo "== 미사용 Calico 포트 제거 (Flannel로 확정) =="
ufw delete allow from "$SUBNET" to any port 179 proto tcp || true
ufw delete allow from "$SUBNET" to any port 4789 proto udp || true

echo "== 상태 확인 =="
ufw status verbose

echo "완료: Stage 1 방화벽 재정리"
