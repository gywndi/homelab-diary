#!/bin/bash
# 경량 RAG(Retrieval-Augmented Generation) 앱 배포.
# 문서를 저장하면 청크로 쪼개 Ollama 임베딩 모델로 벡터화해서 ChromaDB(내장형,
# 별도 서버 없음)에 저장한다. 질문이 오면 같은 방식으로 벡터화해서 유사한
# 청크를 찾고, 그 내용을 컨텍스트로 Qwen2.5에 넘겨 답을 생성한다.
#
# 벡터DB는 Ceph RBD를 쓴다 — ChromaDB는 내부적으로 SQLite를 쓰는데,
# SQLite는 파일 잠금이 제대로 안 되는 네트워크 스토리지(NAS의 nfs-nas,
# nolock 구성)에서 손상 위험이 있다고 공식 문서가 경고한다. RBD는 진짜
# 블록 디바이스라 이 문제가 없다.
#
# 사전 조건: 01-deploy-ollama.sh 완료 + qwen2.5:7b, nomic-embed-text pull 완료
# 사용법: kubectl 접근 가능한 계정으로 실행
#   ./02-deploy-rag-app.sh

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

kubectl -n llm create configmap rag-app-code \
  --from-file=app.py="${DIR}/rag-app.py" \
  --dry-run=client -o yaml | kubectl apply -f -

cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: rag-vectordb
  namespace: llm
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: ceph-csi-rbd
  resources:
    requests:
      storage: 2Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rag-app
  namespace: llm
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: rag-app
  template:
    metadata:
      labels:
        app: rag-app
    spec:
      containers:
        - name: rag-app
          image: python:3.12-slim
          command: ["/bin/sh", "-c"]
          args:
            - |
              pip install --no-cache-dir fastapi uvicorn 'chromadb==0.5.23' requests > /tmp/pip.log 2>&1
              exec uvicorn app:app --host 0.0.0.0 --port 8000 --app-dir /app
          env:
            - name: OLLAMA_URL
              value: "http://ollama.llm.svc.cluster.local:11434"
            - name: GEN_MODEL
              value: "qwen2.5:7b"
            - name: EMBED_MODEL
              value: "nomic-embed-text"
          ports:
            - containerPort: 8000
          readinessProbe:
            # pip install이 끝나 uvicorn이 실제로 뜨기 전까지는 Ready 아님으로 표시
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 30
          volumeMounts:
            - name: code
              mountPath: /app
            - name: data
              mountPath: /data
          resources:
            requests:
              memory: "512Mi"
              cpu: "250m"
            limits:
              memory: "1Gi"
              cpu: "1"
      volumes:
        - name: code
          configMap:
            name: rag-app-code
        - name: data
          persistentVolumeClaim:
            claimName: rag-vectordb
---
apiVersion: v1
kind: Service
metadata:
  name: rag-app
  namespace: llm
spec:
  selector:
    app: rag-app
  ports:
    - port: 8000
EOF

echo "== 파드 기동 대기 (pip install 때문에 시간이 좀 걸림) =="
kubectl -n llm rollout status deployment/rag-app --timeout=300s
kubectl -n llm get pods -o wide

echo "완료: RAG 앱 기동됨 (POST /documents, POST /ask)"
