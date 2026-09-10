#!/bin/bash
# Ollama 배포 — llm001의 GPU를 써서 LLM을 서빙한다. 모델 가중치는 지연에
# 민감하지 않은 대용량 정적 데이터라 NAS(nfs-nas)에 저장한다.
#
# 사전 조건: lessons/05-llm-gpu-node.md 완료(GPU 스케줄링 가능한 상태)
# 사용법: kubectl 접근 가능한 계정으로 실행
#   ./01-deploy-ollama.sh

set -euo pipefail

kubectl create namespace llm --dry-run=client -o yaml | kubectl apply -f -

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ollama-models
  namespace: llm
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: nfs-nas
  resources:
    requests:
      storage: 50Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ollama
  namespace: llm
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: ollama
  template:
    metadata:
      labels:
        app: ollama
    spec:
      containers:
        - name: ollama
          image: ollama/ollama:latest
          ports:
            - containerPort: 11434
          resources:
            requests:
              memory: "8Gi"
              cpu: "2"
            limits:
              memory: "16Gi"
              cpu: "4"
              nvidia.com/gpu: 1
          volumeMounts:
            - name: models
              mountPath: /root/.ollama
      volumes:
        - name: models
          persistentVolumeClaim:
            claimName: ollama-models
---
apiVersion: v1
kind: Service
metadata:
  name: ollama
  namespace: llm
spec:
  selector:
    app: ollama
  ports:
    - port: 11434
EOF

echo "== 파드 기동 대기 =="
kubectl -n llm rollout status deployment/ollama --timeout=180s
kubectl -n llm get pods -o wide

echo "완료: Ollama 기동됨. 다음: 02-pull-models.sh로 모델 다운로드"
