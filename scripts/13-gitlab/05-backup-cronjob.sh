#!/bin/bash
# GitLab 일일 백업 CronJob을 만든다. 앱 데이터 백업과 /etc/gitlab 설정 백업을 NAS(NFS) 마운트로 복사하고 14일 지난 파일을 지운다.
# 파드 안에서 root로 복사하는 이유: NAS는 root만 쓸 수 있고 GitLab 실행 계정(git)은 쓰기가 거부된다.
#
# 사용법: ./05-backup-cronjob.sh

set -euo pipefail

cat <<'EOF' | kubectl apply -f -
# GitLab 일일 백업 → NAS. kubectl exec로 GitLab 파드 안에서 실행한다.
#  1) gitlab-backup create : 저장소/DB/업로드 등 앱 데이터 (로컬 RBD /var/opt/gitlab/backups, git 계정)
#  2) 최신 백업 tar와 /etc/gitlab(gitlab-secrets.json 포함) 압축본을 NAS 마운트로 복사 (root)
#  3) NAS에서 14일 지난 파일 삭제
# gitlab-secrets.json이 없으면 DB 백업만으로는 2FA/CI 변수 등을 복호화할 수 없으므로 설정도 같이 보관한다.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: gitlab-backup
  namespace: gitlab
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: gitlab-backup
  namespace: gitlab
rules:
  - apiGroups: [""]
    resources: [pods]
    verbs: [get, list]
  - apiGroups: [""]
    resources: [pods/exec]
    verbs: [create]
  - apiGroups: [apps]
    resources: [deployments]
    verbs: [get]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: gitlab-backup
  namespace: gitlab
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: gitlab-backup
subjects:
  - kind: ServiceAccount
    name: gitlab-backup
    namespace: gitlab
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: gitlab-backup
  namespace: gitlab
spec:
  schedule: "0 3 * * *"
  timeZone: Asia/Seoul
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 0
      template:
        spec:
          serviceAccountName: gitlab-backup
          restartPolicy: Never
          containers:
            - name: backup
              image: alpine:3.20
              command:
                - /bin/sh
                - -c
                - |
                  set -e
                  kubectl -n gitlab exec deploy/gitlab -- bash -ec '
                    gitlab-backup create STRATEGY=copy CRON=1
                    ts=$(date +%Y%m%d-%H%M%S)
                    latest=$(ls -t /var/opt/gitlab/backups/*_gitlab_backup.tar | head -1)
                    cp "$latest" /mnt/nas-backup/
                    tar czf /mnt/nas-backup/gitlab-config_$ts.tgz -C /etc gitlab
                    find /mnt/nas-backup -type f -mtime +14 -delete
                    ls -lh /mnt/nas-backup | tail -6'
              volumeMounts:
                - { name: kubectl, mountPath: /usr/local/bin/kubectl, readOnly: true }
          volumes:
            # 노드에 설치된 kubectl(정적 바이너리)을 재사용한다.
            - name: kubectl
              hostPath:
                path: /usr/bin/kubectl
                type: File
EOF
