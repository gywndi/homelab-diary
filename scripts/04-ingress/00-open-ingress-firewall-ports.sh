#!/bin/bash
# Ingress 계층(MetalLB + ingress-nginx)에 필요한 방화벽 포트를 연다 (양쪽 노드 모두 실행)
#
# 80/443은 지금까지의 규칙과 다르게 내부망(10.5.5.0/24)이 아니라 인터넷 전체에서
# 들어오는 트래픽을 받아야 한다 (집 공유기가 포트포워딩해주는 대상이 이 두 포트).
#
# 사용법: sudo ./00-open-ingress-firewall-ports.sh

set -euo pipefail

SUBNET="10.5.5.0/24"

echo "== MetalLB memberlist (speaker 간 리더 선출용 가십 프로토콜) =="
ufw allow from "$SUBNET" to any port 7946 proto tcp comment 'MetalLB memberlist'
ufw allow from "$SUBNET" to any port 7946 proto udp comment 'MetalLB memberlist'

echo "== HTTP (ingress, ACME HTTP-01 챌린지) - 인터넷 전체에서 허용 =="
ufw allow 80/tcp comment 'HTTP (ingress, ACME)'

echo "== HTTPS (ingress) - 인터넷 전체에서 허용 =="
ufw allow 443/tcp comment 'HTTPS (ingress)'

ufw reload

echo "== 확인 =="
ufw status verbose

echo "완료: ingress 방화벽 포트 추가"
