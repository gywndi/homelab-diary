#!/bin/bash
# 내부 DNS(CoreDNS)에 GitLab 이름 두 개를 직접 등록한다.
#  - gitlab-ssh.k8s.home -> 10.5.5.55 : SSH는 ingress를 거치지 않고 VIP로 바로 가야 한다.
#  - <공인 도메인>       -> 10.5.5.50 : 공유기 DNS가 새 이름에 NXDOMAIN을 간헐적으로 주므로, 공유기에 묻지 않고 직접 답한다.
#
# 사용법: ./03-add-ssh-dns.sh <도메인>
#   예: ./03-add-ssh-dns.sh gitlab.example.com

set -euo pipefail

DOMAIN="${1:-}"
if [[ -z "$DOMAIN" ]]; then
  echo "사용법: $0 <도메인>" >&2
  exit 1
fi

kubectl -n internal-dns get cm internal-dns-corefile -o json | DOMAIN="$DOMAIN" python3 -I -c "
import os, sys, json
d = json.load(sys.stdin)
c = d['data']['Corefile']
# 다른 템플릿 블록에도 같은 들여쓰기의 fallthrough가 있다. hosts 블록의 것만 골라 그 앞에 넣는다
start = c.index('hosts /etc/coredns/customhosts {')
for line in ('      10.5.5.55 gitlab-ssh.k8s.home\\n', '      10.5.5.50 ' + os.environ['DOMAIN'] + '\\n'):
    if line not in c:
        end = c.index('      fallthrough\\n', start)
        c = c[:end] + line + c[end:]
print(json.dumps({'data': {'Corefile': c}}))" > /tmp/corefile-patch.json

kubectl -n internal-dns patch cm internal-dns-corefile --type merge --patch-file /tmp/corefile-patch.json

# ConfigMap은 마운트 갱신이 늦을 수 있어 재시작으로 즉시 반영한다.
kubectl -n internal-dns rollout restart deploy/internal-dns
kubectl -n internal-dns rollout status deploy/internal-dns
