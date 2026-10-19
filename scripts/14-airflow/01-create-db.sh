#!/bin/bash
# Airflow 메타데이터용 DB/계정을 기존 MySQL(k8s mysql 네임스페이스)에 만들고 접속 정보를 Secret으로 저장한다.
# 비밀번호는 실행할 때마다 새로 생성하며 이미 Secret이 있으면 그대로 둔다(재실행 안전).
set -euo pipefail

kubectl create namespace airflow --dry-run=client -o yaml | kubectl apply -f -

if kubectl -n airflow get secret airflow-secrets >/dev/null 2>&1; then
  echo "airflow-secrets 가 이미 있어 건너뜀"
  exit 0
fi

DB_PW=$(openssl rand -hex 16)
FERNET=$(openssl rand -base64 32 | tr '+/' '-_')
JWT=$(openssl rand -hex 32)
API_KEY=$(openssl rand -hex 32)
ADMIN_PW=$(openssl rand -hex 8)

# MySQL root는 비밀번호 없이 파드 안 소켓으로 접속한다(MYSQL_ALLOW_EMPTY_PASSWORD).
kubectl -n mysql exec deploy/mysql -- mysql -uroot -e "
CREATE DATABASE IF NOT EXISTS airflow CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'airflow'@'%' IDENTIFIED BY '${DB_PW}';
ALTER USER 'airflow'@'%' IDENTIFIED BY '${DB_PW}';
GRANT ALL PRIVILEGES ON airflow.* TO 'airflow'@'%';"

kubectl -n airflow create secret generic airflow-secrets \
  --from-literal=sql-alchemy-conn="mysql+mysqldb://airflow:${DB_PW}@mysql.mysql.svc.cluster.local:3306/airflow" \
  --from-literal=fernet-key="${FERNET}" \
  --from-literal=jwt-secret="${JWT}" \
  --from-literal=api-secret-key="${API_KEY}" \
  --from-literal=admin-password="${ADMIN_PW}"
echo "완료. 관리자 비밀번호 확인: kubectl -n airflow get secret airflow-secrets -o jsonpath='{.data.admin-password}' | base64 -d"
