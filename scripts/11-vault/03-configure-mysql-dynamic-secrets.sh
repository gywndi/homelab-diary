#!/bin/bash
# Vault의 database secrets engine을 MySQL에 연결 — 요청 시점에 짧은 수명
# 자격증명을 즉석 생성하는 동적 시크릿을 시연한다.
#
# 사전 조건: 02-init-unseal.sh 완료, MySQL에 vault 전용 관리 계정이 있을 것
#   (CREATE USER 권한 + 동적 유저가 받을 권한을 GRANT할 수 있는 권한 필요)
# 사용법: ./03-configure-mysql-dynamic-secrets.sh <root token> <MySQL vault 계정 비밀번호>
#   예: ./03-configure-mysql-dynamic-secrets.sh hvs.xxxx 'abcd1234'

set -euo pipefail

VAULT_TOKEN="${1:-}"
MYSQL_VAULT_PW="${2:-}"
if [[ -z "$VAULT_TOKEN" || -z "$MYSQL_VAULT_PW" ]]; then
  echo "사용법: $0 <root token> <MySQL vault 계정 비밀번호>" >&2
  exit 1
fi

echo "== 데모용 DB/테이블 + Vault 전용 MySQL 관리 계정 준비 =="
kubectl -n mysql exec deploy/mysql -- mysql -uroot -e "
CREATE DATABASE IF NOT EXISTS vault_demo;
CREATE TABLE IF NOT EXISTS vault_demo.items (id INT PRIMARY KEY, name VARCHAR(50));
INSERT IGNORE INTO vault_demo.items VALUES (1,'widget'),(2,'gadget');
CREATE USER IF NOT EXISTS 'vault'@'%' IDENTIFIED BY '${MYSQL_VAULT_PW}';
GRANT CREATE USER ON *.* TO 'vault'@'%' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON vault_demo.* TO 'vault'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
"

echo "== database secrets engine 활성화 + MySQL 연결 =="
kubectl -n vault exec vault-0 -- env VAULT_TOKEN="$VAULT_TOKEN" vault secrets enable database

kubectl -n vault exec vault-0 -- env VAULT_TOKEN="$VAULT_TOKEN" vault write database/config/mysql-demo \
  plugin_name=mysql-database-plugin \
  connection_url="{{username}}:{{password}}@tcp(mysql.mysql.svc.cluster.local:3306)/" \
  allowed_roles="readonly" \
  username="vault" \
  password="$MYSQL_VAULT_PW"

echo "== readonly 역할 정의 (기본 5분, 최대 1시간 TTL) =="
kubectl -n vault exec vault-0 -- env VAULT_TOKEN="$VAULT_TOKEN" vault write database/roles/readonly \
  db_name=mysql-demo \
  creation_statements="CREATE USER '{{name}}'@'%' IDENTIFIED BY '{{password}}'; GRANT SELECT ON vault_demo.* TO '{{name}}'@'%';" \
  default_ttl="5m" \
  max_ttl="1h"

echo "완료: database/creds/readonly 로 동적 자격증명 발급 가능"
echo "  vault read database/creds/readonly"
