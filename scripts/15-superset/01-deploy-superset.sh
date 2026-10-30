#!/bin/bash
# Superset 을 k8s 에 가장 가볍게 배포한다: 파드 1개, 메타데이터 DB 는 내장 SQLite(Ceph PVC), Redis/Celery 없음.
# 비밀 값(SECRET_KEY, admin 비밀번호)은 실행할 때 생성해 Secret 에 넣는다. 이미 Secret 이 있으면 다시 만들지 않는다.
# 사용법: ./01-deploy-superset.sh [도메인]
#   도메인을 주면 ingress(letsencrypt-prod)도 만든다. 없으면 ClusterIP 만 둔다: kubectl -n superset port-forward svc/superset 8088:8088
#   도메인은 먼저 내부 DNS 에 등록해야 인증서가 발급된다: scripts/13-gitlab/03-add-ssh-dns.sh <도메인>
set -euo pipefail

DOMAIN="${1:-}"
IMAGE="apache/superset:6.1.0-py312"

kubectl create namespace superset --dry-run=client -o yaml | kubectl apply -f -

if ! kubectl -n superset get secret superset-secrets >/dev/null 2>&1; then
  kubectl -n superset create secret generic superset-secrets \
    --from-literal=secret-key="$(openssl rand -base64 42)" \
    --from-literal=admin-password="$(openssl rand -hex 12)"
fi

cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: superset-home
  namespace: superset
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ceph-csi-rbd
  resources:
    requests:
      storage: 2Gi
---
apiVersion: v1
kind: Service
metadata:
  name: superset
  namespace: superset
spec:
  selector:
    app: superset
  ports:
    - port: 8088
      targetPort: 8088
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: superset
  namespace: superset
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: superset
  template:
    metadata:
      labels:
        app: superset
    spec:
      # 서비스 이름이 superset 이면 k8s 가 SUPERSET_PORT=tcp://... 를 주입하고, Superset 이 이를 포트 번호로 읽다 죽는다
      enableServiceLinks: false
      securityContext:
        fsGroup: 1000
      containers:
        - name: superset
          image: ${IMAGE}
          # 이미지의 venv 는 쓰기 불가라 Snowflake 드라이버는 PVC(pylibs)에 설치해 PYTHONPATH 로 읽는다. SQLAlchemy 2.x 로 올라가면 Superset 이 깨지므로 1.4 로 고정한다.
          # 이어서 메타데이터 DB 마이그레이션 → admin 생성(이미 있으면 건너뜀) → 기본 권한/역할 초기화 → 웹 서버 기동
          command: ["bash", "-c", "set -e; uv pip install --quiet --python /app/.venv/bin/python --target /app/superset_home/pylibs \"snowflake-sqlalchemy<2\" \"sqlalchemy<1.5\"; superset db upgrade; superset fab create-admin --username admin --firstname Admin --lastname User --email admin@example.com --password \"\$ADMIN_PASSWORD\" || echo 'admin 이미 있음'; superset init; exec /usr/bin/run-server.sh"]
          ports:
            - containerPort: 8088
          env:
            - name: SUPERSET_SECRET_KEY
              valueFrom: {secretKeyRef: {name: superset-secrets, key: secret-key}}
            - name: ADMIN_PASSWORD
              valueFrom: {secretKeyRef: {name: superset-secrets, key: admin-password}}
            - name: PYTHONPATH
              value: /app/superset_home/pylibs
            - name: TZ
              value: Asia/Seoul
          resources:
            requests: {cpu: 200m, memory: 1Gi}
            limits: {memory: 2Gi}
          readinessProbe:
            httpGet: {path: /health, port: 8088}
            initialDelaySeconds: 60
            periodSeconds: 15
          volumeMounts:
            - {name: home, mountPath: /app/superset_home}
      volumes:
        - name: home
          persistentVolumeClaim: {claimName: superset-home}
YAML

if [[ -n "$DOMAIN" ]]; then
cat <<YAML | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: superset
  namespace: superset
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
    - hosts: [${DOMAIN}]
      secretName: superset-tls
  rules:
    - host: ${DOMAIN}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: {name: superset, port: {number: 8088}}
YAML
fi

kubectl -n superset rollout status deploy/superset --timeout=900s
echo "접속: kubectl -n superset port-forward svc/superset 8088:8088  → http://localhost:8088 (admin / superset-secrets의 admin-password)"
