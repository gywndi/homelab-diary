#!/bin/bash
# GitLab의 공인 도메인을 새 이름으로 바꾼다. 기존 도메인은 ingress에 남겨 두어 접속이 끊기지 않는다.
#  1. 내부 DNS에 새 이름을 등록한다 (03-add-ssh-dns.sh 재사용).
#  2. ingress에 새 호스트를 추가하고, Let's Encrypt 인증서에 새 이름이 들어올 때까지 기다린다.
#  3. GitLab의 external_url을 새 이름으로 바꾸고 재기동한다. Recreate 전략이라 몇 분 내려간다.
#  4. Runner가 있으면 접속 주소를 새 이름으로 바꾼다.
# 공인 DNS(A 레코드)는 미리 집 공인 IP를 가리켜야 한다. 인증서 발급(HTTP-01)이 이 경로를 쓴다.
#
# 사용법: ./09-change-domain.sh <새 도메인>
#   예: ./09-change-domain.sh git.example.com

set -euo pipefail

NEW="${1:-}"
if [[ -z "$NEW" ]]; then
  echo "사용법: $0 <새 도메인>" >&2
  exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"

# 현재 external_url의 도메인을 읽는다
OLD=$(kubectl -n gitlab get deploy gitlab -o json | python3 -I -c "
import sys, json, re
d = json.load(sys.stdin)
env = d['spec']['template']['spec']['containers'][0]['env']
v = [e['value'] for e in env if e['name'] == 'GITLAB_OMNIBUS_CONFIG'][0]
print(re.search(r\"external_url 'https://([^']+)'\", v).group(1))")
echo "현재 도메인: $OLD -> 새 도메인: $NEW"

echo "== 1. 내부 DNS 등록 =="
"$HERE/03-add-ssh-dns.sh" "$NEW"

echo "== 2. ingress에 새 호스트 추가 =="
kubectl -n gitlab get ingress gitlab -o json | NEW="$NEW" python3 -I -c "
import os, sys, json, copy
d = json.load(sys.stdin)
new = os.environ['NEW']
spec = d['spec']
if not any(r.get('host') == new for r in spec['rules']):
    rule = copy.deepcopy(spec['rules'][0])
    rule['host'] = new
    spec['rules'].append(rule)
if new not in spec['tls'][0]['hosts']:
    spec['tls'][0]['hosts'].append(new)
print(json.dumps({'spec': {'rules': spec['rules'], 'tls': spec['tls']}}))" > /tmp/gitlab-ingress-patch.json
kubectl -n gitlab patch ingress gitlab --type merge --patch-file /tmp/gitlab-ingress-patch.json

echo "== 인증서에 새 이름이 들어올 때까지 대기 (최대 5분) =="
for _ in $(seq 1 60); do
  if kubectl -n gitlab get secret gitlab-tls -o jsonpath='{.data.tls\.crt}' | base64 -d \
      | openssl x509 -noout -ext subjectAltName 2>/dev/null | grep -q "$NEW"; then
    echo "인증서 발급 완료"
    break
  fi
  sleep 5
done
kubectl -n gitlab get secret gitlab-tls -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -ext subjectAltName | grep -q "$NEW" \
  || { echo "인증서에 $NEW 가 없다. kubectl -n gitlab describe certificate gitlab-tls 를 확인한다." >&2; exit 1; }

echo "== 3. external_url 변경 =="
if [[ "$OLD" == "$NEW" ]]; then
  echo "이미 $NEW 를 쓰고 있어 건너뜀"
else
  kubectl -n gitlab get deploy gitlab -o json | OLD="$OLD" NEW="$NEW" python3 -I -c "
import os, sys, json
d = json.load(sys.stdin)
for e in d['spec']['template']['spec']['containers'][0]['env']:
    if e['name'] == 'GITLAB_OMNIBUS_CONFIG':
        e['value'] = e['value'].replace(\"external_url 'https://\" + os.environ['OLD'] + \"'\", \"external_url 'https://\" + os.environ['NEW'] + \"'\")
print(json.dumps(d))" | kubectl replace -f -
  kubectl -n gitlab rollout status deploy/gitlab --timeout=900s
fi

echo "== 4. Runner 접속 주소 변경 =="
if kubectl -n gitlab-runner get cm gitlab-runner-config >/dev/null 2>&1; then
  kubectl -n gitlab-runner get cm gitlab-runner-config -o json | OLD="$OLD" NEW="$NEW" python3 -I -c "
import os, sys, json
d = json.load(sys.stdin)
d['data']['config.toml'] = d['data']['config.toml'].replace('https://' + os.environ['OLD'], 'https://' + os.environ['NEW'])
print(json.dumps(d))" | kubectl replace -f -
  kubectl -n gitlab-runner rollout restart deploy/gitlab-runner
  kubectl -n gitlab-runner rollout status deploy/gitlab-runner --timeout=300s
else
  echo "Runner가 없어 건너뜀"
fi

echo "== 확인 =="
curl -s -o /dev/null -w "https://$NEW -> %{http_code} verify=%{ssl_verify_result}\n" "https://$NEW/users/sign_in"
