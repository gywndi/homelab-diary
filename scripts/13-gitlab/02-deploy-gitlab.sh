#!/bin/bash
# GitLab CE(Omnibus 이미지 단일 파드)를 k8s에 배포한다.
# Deployment(replicas=1, Recreate) + Ceph RBD PVC 구성이라 노드가 죽으면 다른 노드에서 다시 뜬다.
# 인증서는 기존 cert-manager의 letsencrypt-prod(HTTP-01)로 발급한다.
#
# 사용법: ./02-deploy-gitlab.sh <도메인>
#   예: ./02-deploy-gitlab.sh gitlab.example.com

set -euo pipefail

DOMAIN="${1:-}"
if [[ -z "$DOMAIN" ]]; then
  echo "사용법: $0 <도메인>" >&2
  exit 1
fi

cat <<EOF | kubectl apply -f -
# GitLab CE (Omnibus 이미지 단일 파드) — Deployment(replicas=1, Recreate) + Ceph RBD PVC.
# MySQL과 같은 shared-disk failover 패턴. 노드 장애 시 어느 노드로든 재스케줄된다(nodeSelector 없음).
apiVersion: v1
kind: Namespace
metadata:
  name: gitlab
---
# 데이터/설정/로그를 PVC 하나에 subPath로 나눠 담는다 — RBD 볼륨이 하나여야 attach/detach가 한 번이다.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: gitlab-data
  namespace: gitlab
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ceph-csi-rbd
  resources:
    requests:
      storage: 100Gi
---
# NAS(NFS) 백업 보관소. NAS는 root만 쓰기 가능해서(git 계정은 거부) GitLab이 직접 쓰지 않고,
# root로 실행되는 백업 CronJob이 복사해 넣는다.
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: gitlab-backup
  namespace: gitlab
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: nfs-nas
  resources:
    requests:
      storage: 50Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gitlab
  namespace: gitlab
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: gitlab
  template:
    metadata:
      labels:
        app: gitlab
    spec:
      # 노드 장애 시 eviction 대기를 기본 300초에서 5초로 줄인다.
      tolerations:
        - key: node.kubernetes.io/unreachable
          operator: Exists
          effect: NoExecute
          tolerationSeconds: 5
        - key: node.kubernetes.io/not-ready
          operator: Exists
          effect: NoExecute
          tolerationSeconds: 5
      terminationGracePeriodSeconds: 60
      containers:
        - name: gitlab
          image: gitlab/gitlab-ce:19.4.2-ce.0
          ports:
            - name: http
              containerPort: 80
            - name: ssh
              containerPort: 22
          env:
            - name: GITLAB_OMNIBUS_CONFIG
              value: |
                external_url 'https://${DOMAIN}'
                nginx['listen_port'] = 80
                nginx['listen_https'] = false
                # TLS는 ingress-nginx가 종료한다. 파드 안 nginx가 https로 오인하지 않도록 프록시 헤더를 고정한다.
                nginx['proxy_set_headers'] = { 'X-Forwarded-Proto' => 'https', 'X-Forwarded-Ssl' => 'on' }
                # 로컬(RBD) 백업은 3일만 보관한다. 장기 보관본은 NAS 마운트로 복사한다(CronJob).
                gitlab_rails['backup_keep_time'] = 259200
                gitlab_rails['gitlab_shell_ssh_port'] = 22
                gitlab_rails['gitlab_ssh_host'] = 'gitlab-ssh.k8s.home'
                gitlab_rails['time_zone'] = 'Asia/Seoul'
                # kubelet 프로브는 노드의 CNI 주소(10.244.x.1)로 들어온다. 허용하지 않으면 /-/readiness가 404를 준다.
                gitlab_rails['monitoring_whitelist'] = ['127.0.0.0/8', '10.244.0.0/16']
                # 단일 파드 메모리 절약: 내장 모니터링/레지스트리 끔
                prometheus_monitoring['enable'] = false
                registry['enable'] = false
                puma['worker_processes'] = 2
                sidekiq['concurrency'] = 10
                postgresql['shared_buffers'] = '256MB'
          volumeMounts:
            - { name: data, mountPath: /var/opt/gitlab, subPath: data }
            - { name: data, mountPath: /etc/gitlab, subPath: config }
            - { name: data, mountPath: /var/log/gitlab, subPath: logs }
            - { name: shm, mountPath: /dev/shm }
            - { name: nas-backup, mountPath: /mnt/nas-backup }
          resources:
            requests:
              memory: 4Gi
              cpu: "1"
            limits:
              memory: 8Gi
          # 최초 기동(reconfigure + DB 마이그레이션)은 10분 이상 걸릴 수 있다.
          startupProbe:
            httpGet: { path: /-/readiness, port: http }
            periodSeconds: 10
            failureThreshold: 90
          readinessProbe:
            httpGet: { path: /-/readiness, port: http }
            periodSeconds: 10
            failureThreshold: 3
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: gitlab-data
        - name: nas-backup
          persistentVolumeClaim:
            claimName: gitlab-backup
        - name: shm
          emptyDir:
            medium: Memory
            sizeLimit: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: gitlab-http
  namespace: gitlab
spec:
  selector:
    app: gitlab
  ports:
    - name: http
      port: 80
      targetPort: http
---
# git over SSH 전용 VIP. ingress-nginx는 HTTP만 다루므로 SSH는 별도 LoadBalancer로 노출한다.
apiVersion: v1
kind: Service
metadata:
  name: gitlab-ssh
  namespace: gitlab
  annotations:
    # autoAssign 풀이 여러 개라 풀/IP를 명시하지 않으면 엉뚱한 풀에서 할당된다.
    metallb.io/address-pool: gitlab-pool
    metallb.io/loadBalancerIPs: 10.5.5.55
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local
  selector:
    app: gitlab
  ports:
    - name: ssh
      port: 22
      targetPort: ssh
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: gitlab
  namespace: gitlab
  annotations:
    # push/clone 크기 제한 해제, 긴 요청 허용
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "600"
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
    - hosts: [${DOMAIN}]
      secretName: gitlab-tls
  rules:
    - host: ${DOMAIN}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: gitlab-http
                port:
                  name: http
EOF

echo "== 기동 대기 (최초 기동은 수 분 걸린다) =="
kubectl -n gitlab rollout status deploy/gitlab --timeout=900s
kubectl -n gitlab get pods,pvc,svc,ingress
