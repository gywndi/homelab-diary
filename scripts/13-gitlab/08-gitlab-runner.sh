#!/bin/bash
# GitLab Runner(CI 작업을 실제로 실행하는 에이전트)를 Kubernetes executor로 설치한다.
# Runner 본체는 Deployment 1개이고, CI 작업마다 같은 네임스페이스에 파드를 하나씩 띄워서 실행하고 지운다.
# 인증 토큰은 GitLab에서 인스턴스 Runner를 만들어 받고 Secret에만 저장한다. 이미 Secret이 있으면 Runner를 새로 만들지 않는다.
#
# 사용법: ./08-gitlab-runner.sh <도메인>
#   예: ./08-gitlab-runner.sh gitlab.example.com

set -euo pipefail

DOMAIN="${1:-}"
if [[ -z "$DOMAIN" ]]; then
  echo "사용법: $0 <도메인>" >&2
  exit 1
fi

kubectl create namespace gitlab-runner --dry-run=client -o yaml | kubectl apply -f -

if ! kubectl -n gitlab-runner get secret runner-token >/dev/null 2>&1; then
  echo "== GitLab에서 인스턴스 Runner 생성 (인증 토큰 발급) =="
  TOKEN=$(kubectl -n gitlab exec deploy/gitlab -- gitlab-rails runner '
    user = User.find_by!(username: "root")
    res = ::Ci::Runners::CreateRunnerService.new(user: user, params: {
      runner_type: "instance_type", description: "k8s-runner", tag_list: ["k8s"], run_untagged: true
    }).execute
    abort("runner 생성 실패: #{res.message}") unless res.success?
    puts res.payload[:runner].token
  ' | grep '^glrt-' | tail -1)
  [[ -n "$TOKEN" ]] || { echo "토큰 발급 실패" >&2; exit 1; }
  kubectl -n gitlab-runner create secret generic runner-token --from-literal=token="$TOKEN"
  unset TOKEN
else
  echo "== Secret runner-token 이 이미 있어 Runner 생성을 건너뜀 =="
fi

echo "== Runner 매니페스트 적용 =="
cat <<'EOF' | sed "s|__DOMAIN__|${DOMAIN}|g" | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: gitlab-runner
  namespace: gitlab-runner
---
# Kubernetes executor가 작업 파드를 만들고 지우는 데 필요한 최소 권한 (이 네임스페이스 안으로 한정)
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: gitlab-runner
  namespace: gitlab-runner
rules:
  - apiGroups: [""]
    resources: [pods]
    verbs: [get, list, watch, create, delete]
  - apiGroups: [""]
    resources: [pods/exec, pods/attach]
    verbs: [get, create, patch, delete]
  - apiGroups: [""]
    resources: [pods/log]
    verbs: [get]
  - apiGroups: [""]
    resources: [secrets, configmaps, services]
    verbs: [get, list, create, update, delete]
  - apiGroups: [""]
    resources: [events]
    verbs: [list]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: gitlab-runner
  namespace: gitlab-runner
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: gitlab-runner
subjects:
  - kind: ServiceAccount
    name: gitlab-runner
    namespace: gitlab-runner
---
# 토큰 자리(__TOKEN__)는 컨테이너 시작 시 Secret 값으로 치환한다. 토큰이 ConfigMap에 남지 않게 하기 위해서다.
apiVersion: v1
kind: ConfigMap
metadata:
  name: gitlab-runner-config
  namespace: gitlab-runner
data:
  config.toml: |
    concurrent = 4
    check_interval = 3
    log_level = "info"

    [[runners]]
      name = "k8s-runner"
      url = "https://__DOMAIN__"
      token = "__TOKEN__"
      executor = "kubernetes"
      # 동시 작업이 4개라서 요청도 병렬로 보낸다. 1이면 긴 폴링 때문에 작업 시작이 지연될 수 있다
      request_concurrency = 4

      [runners.kubernetes]
        namespace = "gitlab-runner"
        image = "alpine:3.20"
        poll_timeout = 600
        cpu_request = "100m"
        cpu_limit = "2"
        memory_request = "256Mi"
        memory_limit = "2Gi"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gitlab-runner
  namespace: gitlab-runner
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: gitlab-runner
  template:
    metadata:
      labels:
        app: gitlab-runner
    spec:
      serviceAccountName: gitlab-runner
      containers:
        - name: runner
          image: gitlab/gitlab-runner:alpine-v19.4.1
          command: ["/bin/sh", "-c"]
          args:
            - |
              sed "s|__TOKEN__|${RUNNER_TOKEN}|" /template/config.toml > /etc/gitlab-runner/config.toml
              exec gitlab-runner run --config /etc/gitlab-runner/config.toml
          env:
            - name: RUNNER_TOKEN
              valueFrom:
                secretKeyRef:
                  name: runner-token
                  key: token
          volumeMounts:
            - { name: template, mountPath: /template }
            - { name: config, mountPath: /etc/gitlab-runner }
          resources:
            requests: { cpu: 50m, memory: 128Mi }
            limits: { memory: 512Mi }
      volumes:
        - name: template
          configMap:
            name: gitlab-runner-config
        - name: config
          emptyDir: {}
EOF

kubectl -n gitlab-runner rollout status deploy/gitlab-runner --timeout=300s
kubectl -n gitlab-runner get pods -o wide
