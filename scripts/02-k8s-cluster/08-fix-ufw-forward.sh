#!/bin/bash
# UFW DEFAULT_FORWARD_POLICY가 DROP이면 pod 네트워크(FORWARD 체인) 트래픽이
# 막혀 CoreDNS 등이 API 서버에 도달하지 못한다. ACCEPT로 변경.
# 인바운드 규칙(10.5.5.0/24 제한)에는 영향 없음 — FORWARD 체인만 변경.
#
# 사용법: sudo ./08-fix-ufw-forward.sh (모든 노드에서 실행)

set -euo pipefail

sed -i 's/^DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
grep "^DEFAULT_FORWARD_POLICY" /etc/default/ufw

ufw reload

echo "-- FORWARD policy 확인 --"
iptables -L FORWARD -n | head -1

echo "완료: UFW FORWARD 정책 ACCEPT로 변경"
