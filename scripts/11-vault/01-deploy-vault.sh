#!/bin/bash
# Vault 3replica StatefulSet 배포 (Raft integrated storage, TLS 비활성 — 테스트 목적).
# Helm 대신 이 저장소의 다른 애드온과 같은 방식(raw manifest, kubectl apply)으로 직접 작성한다.
#
# 사용법: kubectl 접근 가능한 계정으로 실행
#   ./01-deploy-vault.sh

set -euo pipefail

kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f -

echo "== Vault 설정(HCL) ConfigMap =="
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: vault-config
  namespace: vault
data:
  vault.hcl: |
    ui = true
    disable_mlock = false
    listener "tcp" {
      address     = "[::]:8200"
      tls_disable = 1
    }
    storage "raft" {
      path = "/vault/data"
      retry_join {
        leader_api_addr = "http://vault-0.vault-internal.vault.svc.cluster.local:8200"
      }
      retry_join {
        leader_api_addr = "http://vault-1.vault-internal.vault.svc.cluster.local:8200"
      }
      retry_join {
        leader_api_addr = "http://vault-2.vault-internal.vault.svc.cluster.local:8200"
      }
    }
EOF

echo "== 헤드리스 Service(Raft 피어 통신용) + 클라이언트 API Service + StatefulSet =="
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: vault-internal
  namespace: vault
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  selector:
    app: vault
  ports:
    - name: http
      port: 8200
    - name: cluster
      port: 8201
---
apiVersion: v1
kind: Service
metadata:
  name: vault
  namespace: vault
spec:
  selector:
    app: vault
  ports:
    - name: http
      port: 8200
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: vault
  namespace: vault
spec:
  serviceName: vault-internal
  replicas: 3
  selector:
    matchLabels:
      app: vault
  template:
    metadata:
      labels:
        app: vault
    spec:
      containers:
        - name: vault
          image: hashicorp/vault:1.20
          command:
            - "/bin/sh"
            - "-ec"
            - |
              export VAULT_API_ADDR="http://${POD_NAME}.vault-internal.vault.svc.cluster.local:8200"
              export VAULT_CLUSTER_ADDR="http://${POD_NAME}.vault-internal.vault.svc.cluster.local:8201"
              exec vault server -config=/vault/config/vault.hcl
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: VAULT_ADDR
              value: "http://127.0.0.1:8200"
          ports:
            - containerPort: 8200
              name: http
            - containerPort: 8201
              name: cluster
          readinessProbe:
            # sealed(503)/미초기화(501)면 Ready 실패 — standby(429)는 standbyok=true로 정상 취급
            httpGet:
              path: /v1/sys/health?standbyok=true
              port: 8200
            initialDelaySeconds: 5
            periodSeconds: 5
          securityContext:
            capabilities:
              add: ["IPC_LOCK"]
          volumeMounts:
            - name: config
              mountPath: /vault/config
            - name: data
              mountPath: /vault/data
      volumes:
        - name: config
          configMap:
            name: vault-config
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: ceph-csi-rbd
        resources:
          requests:
            storage: 2Gi
EOF

echo "== 파드 기동 대기 (컨테이너는 Running이어도 Ready는 0/1 — sealed라 헬스체크 실패하는 게 정상, init 전까지는) =="
sleep 20
kubectl -n vault get pods -o wide

echo "완료: Vault 3개 파드 기동됨(전부 미초기화 상태). 다음: 02-init-unseal.sh"
