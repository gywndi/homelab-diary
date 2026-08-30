#!/bin/bash
# 핵심 인프라 노드(chan08/chan09/llm001)의 /etc/hosts에 내부 도메인을 박아둔다.
# CoreDNS(dns.home, 10.5.5.2)가 이 도메인들을 서비스하지만, 이 3대는 CoreDNS
# 자체를 갱신/재기동할 수도 있는 노드라 DNS에 장애가 나면 자기 자신도 도메인으로
# 접근이 안 되는 닭-달걀 문제가 생긴다. /etc/hosts는 DNS와 무관하게 항상 먹히므로
# 이 3대에 한해 안전망으로 심어둔다.
#
# 새 인프라 노드/VIP를 추가할 땐 아래 목록에도 같은 줄을 추가하고 이 스크립트를
# 3노드(chan08/chan09/llm001) 각각에서 재실행해야 한다 — CoreDNS ConfigMap과 달리
# 이 목록은 파일에 하드코딩돼 있어서 자동으로 따라오지 않는다. 전체 체크리스트는
# lessons/09-internal-dns.md의 "신규 노드/인프라 장비 추가 시" 참고.
#
# 사용법: sudo ./06-hosts-static-entries.sh

set -euo pipefail

MARK_BEGIN="# BEGIN homelab-infra-hosts"
MARK_END="# END homelab-infra-hosts"

echo "== 기존 블록 제거(있으면, 재실행해도 중복 안 되게) =="
sed -i "/^${MARK_BEGIN}\$/,/^${MARK_END}\$/d" /etc/hosts

echo "== 새 블록 추가 =="
cat >> /etc/hosts <<EOF
${MARK_BEGIN}
10.5.5.2 dns.home
10.5.5.3 k8s.home
10.5.5.4 ceph.home
10.5.5.5 nas.home
10.5.5.8 chan08.home
10.5.5.9 chan09.home
10.5.5.10 llm001.home
${MARK_END}
EOF

echo "== 결과 확인 =="
getent hosts dns.home k8s.home ceph.home nas.home chan08.home chan09.home llm001.home

echo "완료: /etc/hosts 정적 항목 등록"
