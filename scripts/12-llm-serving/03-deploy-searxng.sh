#!/bin/bash
# SearXNG(자체 호스팅 메타검색엔진) 배포 — Google/Bing/DDG 등 여러 검색엔진
# 결과를 API 키 없이 JSON으로 모아준다. 지식 수집(collect-coffee-knowledge.py)에
# 쓴다. 상태 없는 검색 프록시라 PVC 불필요.
#
# 사용법: kubectl 접근 가능한 계정으로 실행
#   ./03-deploy-searxng.sh

set -euo pipefail

kubectl -n llm create configmap searxng-config \
  --from-literal=settings.yml="$(cat <<'EOF'
use_default_settings: true
server:
  secret_key: "homelab-searxng-internal-only"
  limiter: false
search:
  formats:
    - html
    - json
EOF
)" \
  --dry-run=client -o yaml | kubectl apply -f -

cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: searxng
  namespace: llm
spec:
  replicas: 1
  selector:
    matchLabels:
      app: searxng
  template:
    metadata:
      labels:
        app: searxng
    spec:
      containers:
        - name: searxng
          image: searxng/searxng:latest
          ports:
            - containerPort: 8080
          volumeMounts:
            - name: config
              mountPath: /etc/searxng
          resources:
            requests:
              memory: "256Mi"
              cpu: "100m"
            limits:
              memory: "512Mi"
              cpu: "500m"
          readinessProbe:
            httpGet:
              path: /
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 5
      volumes:
        - name: config
          configMap:
            name: searxng-config
---
apiVersion: v1
kind: Service
metadata:
  name: searxng
  namespace: llm
spec:
  selector:
    app: searxng
  ports:
    - port: 8080
EOF

echo "== 파드 기동 대기 =="
kubectl -n llm rollout status deployment/searxng --timeout=120s
kubectl -n llm get pods -l app=searxng

echo "완료: SearXNG 기동됨 (내부 전용, http://searxng.llm.svc.cluster.local:8080)"
