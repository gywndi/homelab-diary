#!/bin/bash
# Airflow 3 를 k8s 에 가장 가볍게 배포한다: 파드 1개, `airflow standalone`(api-server+scheduler+dag-processor+triggerer),
# LocalExecutor, 메타데이터 DB 는 기존 MySQL. DAG 는 GitLab(GitDagBundle), 로그는 작은 PVC.
#
# 사용법: ./02-deploy-airflow.sh [도메인]
#   도메인을 주면 ingress(letsencrypt-prod)도 만든다. 없으면 port-forward 로만 접속한다.
set -euo pipefail

DOMAIN="${1:-}"
IMAGE="apache/airflow:3.3.2-python3.12"

cat <<YAML | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: airflow-logs
  namespace: airflow
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ceph-csi-rbd
  resources:
    requests:
      storage: 5Gi
---
apiVersion: v1
kind: Service
metadata:
  name: airflow
  namespace: airflow
spec:
  selector:
    app: airflow
  ports:
    - port: 8080
      targetPort: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: airflow
  namespace: airflow
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: airflow
  template:
    metadata:
      labels:
        app: airflow
    spec:
      securityContext:
        fsGroup: 0
      containers:
        - name: airflow
          image: ${IMAGE}
          command: ["airflow", "standalone"]
          ports:
            - containerPort: 8080
          env:
            - name: AIRFLOW__CORE__EXECUTOR
              value: LocalExecutor
            - name: AIRFLOW__CORE__LOAD_EXAMPLES
              value: "False"
            - name: AIRFLOW__CORE__TEST_CONNECTION
              value: Enabled
            - name: AIRFLOW__CORE__PARALLELISM
              value: "8"
            - name: AIRFLOW__CORE__SIMPLE_AUTH_MANAGER_USERS
              value: "admin:admin,viewer:viewer"
            - name: AIRFLOW__CORE__SIMPLE_AUTH_MANAGER_PASSWORDS_FILE
              value: /opt/airflow/auth/passwords.json
            - name: AIRFLOW__DATABASE__SQL_ALCHEMY_CONN
              valueFrom: {secretKeyRef: {name: airflow-secrets, key: sql-alchemy-conn}}
            - name: AIRFLOW__CORE__FERNET_KEY
              valueFrom: {secretKeyRef: {name: airflow-secrets, key: fernet-key}}
            - name: AIRFLOW__API_AUTH__JWT_SECRET
              valueFrom: {secretKeyRef: {name: airflow-secrets, key: jwt-secret}}
            - name: AIRFLOW__API__SECRET_KEY
              valueFrom: {secretKeyRef: {name: airflow-secrets, key: api-secret-key}}
            - name: ADMIN_PASSWORD
              valueFrom: {secretKeyRef: {name: airflow-secrets, key: admin-password}}
            - name: TZ
              value: Asia/Seoul
            # DAG 는 GitLab 저장소(main)를 GitDagBundle 이 1분마다 가져온다. 접속 정보는 airflow-git Secret(04 스크립트).
            - name: AIRFLOW__DAG_PROCESSOR__DAG_BUNDLE_CONFIG_LIST
              value: '[{"name":"airflow-dags","classpath":"airflow.providers.git.bundles.git.GitDagBundle","kwargs":{"git_conn_id":"gitlab_dags","tracking_ref":"main","subdir":"dags","refresh_interval":60}}]'
            - name: AIRFLOW_CONN_GITLAB_DAGS
              valueFrom: {secretKeyRef: {name: airflow-git, key: conn}}
          resources:
            requests: {cpu: 300m, memory: 1Gi}
            limits: {memory: 2Gi}
          readinessProbe:
            httpGet: {path: /api/v2/monitor/health, port: 8080}
            initialDelaySeconds: 60
            periodSeconds: 15
          volumeMounts:
            - {name: logs, mountPath: /opt/airflow/logs}
            - {name: auth, mountPath: /opt/airflow/auth}
      initContainers:
        - name: init-auth
          image: ${IMAGE}
          # viewer-password 가 없으면 viewer 의 비밀번호를 만들지 않아 viewer 로는 로그인할 수 없다(빈 비밀번호 방지)
          command: ["bash", "-c", "if [ -n \"\$VIEWER_PASSWORD\" ]; then printf '{\"admin\": \"%s\", \"viewer\": \"%s\"}' \"\$ADMIN_PASSWORD\" \"\$VIEWER_PASSWORD\"; else printf '{\"admin\": \"%s\"}' \"\$ADMIN_PASSWORD\"; fi > /opt/airflow/auth/passwords.json"]
          env:
            - name: ADMIN_PASSWORD
              valueFrom: {secretKeyRef: {name: airflow-secrets, key: admin-password}}
            - name: VIEWER_PASSWORD
              valueFrom: {secretKeyRef: {name: airflow-secrets, key: viewer-password, optional: true}}
          volumeMounts:
            - {name: auth, mountPath: /opt/airflow/auth}
      volumes:
        - name: logs
          persistentVolumeClaim: {claimName: airflow-logs}
        - name: auth
          emptyDir: {}
YAML

if [[ -n "$DOMAIN" ]]; then
  cat <<YAML | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: airflow
  namespace: airflow
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
    - hosts: [${DOMAIN}]
      secretName: airflow-tls
  rules:
    - host: ${DOMAIN}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: {name: airflow, port: {number: 8080}}
YAML
fi

kubectl -n airflow rollout status deploy/airflow --timeout=600s
echo "접속: kubectl -n airflow port-forward svc/airflow 8080:8080  → http://localhost:8080 (admin / airflow-secrets의 admin-password, 읽기 전용 viewer / viewer-password)"
