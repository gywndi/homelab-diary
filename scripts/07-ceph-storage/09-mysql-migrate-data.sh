#!/bin/bash
# MySQL 데이터를 기존 호스트(/home/mysql)에서 RBD PVC로 이전한다.
# 실행 중인 native mysqld를 정지시키므로 다운타임이 발생한다 — 이 스크립트를
# 실행하는 순간부터 데이터 복사 완료 + 새 파드 기동까지가 다운타임 구간이다.
#
# 사전 조건: 08-mysql-configmap-pvc.yaml 적용 완료(namespace/configmap/pvc 존재)
# 사용법: 소스 호스트(예: chan08)에서 실행. sudo 필요.
#   ./09-mysql-migrate-data.sh <소스 datadir 경로>
#   예: ./09-mysql-migrate-data.sh /home/mysql

set -euo pipefail

SRC="${1:-}"
if [[ -z "$SRC" ]]; then
  echo "사용법: $0 <소스 datadir 경로>" >&2
  exit 1
fi

echo "== 임시 loader 파드 생성 (PVC만 마운트) =="
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: mysql-data-loader
  namespace: mysql
spec:
  containers:
    - name: loader
      image: ubuntu:24.04
      command: ["sleep", "3600"]
      volumeMounts:
        - name: data
          mountPath: /var/lib/mysql
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: mysql-data
EOF
kubectl -n mysql wait --for=condition=Ready pod/mysql-data-loader --timeout=120s

echo "== mysqld 정지 (다운타임 시작 $(date)) =="
sudo systemctl stop mysql

echo "== tar 스트림 복사 (원본 크기에 따라 수 분 소요) =="
sudo tar -C "$SRC" -cf - . | kubectl exec -i -n mysql mysql-data-loader -- tar -C /var/lib/mysql -xf -

echo "== 크기 비교 =="
sudo du -sh "$SRC"
kubectl -n mysql exec mysql-data-loader -- du -sh /var/lib/mysql

echo "== 소유권 설정 (공식 mysql 이미지 규격 999:999) =="
kubectl -n mysql exec mysql-data-loader -- chown -R 999:999 /var/lib/mysql

echo "== loader 파드 정리 =="
kubectl -n mysql delete pod mysql-data-loader --wait=true

echo "완료: 데이터 이전 (다음 단계: 10-mysql-deploy.sh로 실제 파드 배포)"
