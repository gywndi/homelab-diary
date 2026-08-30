#!/bin/bash
# nvidia-device-plugin DaemonSet을 설치해 nvidia.com/gpu 리소스를 노출
#
# GPU 라벨이 붙은 노드에만 스케줄되고, 어떤 taint가 있든(컨트롤플레인 등)
# 살아남도록 와일드카드 toleration을 쓴다 — 이 노드가 나중에 컨트롤플레인으로
# 승격되는 등 taint 구성이 바뀌어도 재조정 없이 계속 떠 있게 하기 위함.
#
# 사용법: ./05-apply-nvidia-device-plugin.sh

set -euo pipefail

cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nvidia-device-plugin-daemonset
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: nvidia-device-plugin-ds
  updateStrategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        name: nvidia-device-plugin-ds
    spec:
      nodeSelector:
        nvidia.com/gpu: "true"
      tolerations:
        - operator: Exists
      priorityClassName: system-node-critical
      containers:
        - image: nvcr.io/nvidia/k8s-device-plugin:v0.17.1
          name: nvidia-device-plugin-ctr
          env:
            - name: FAIL_ON_INIT_ERROR
              value: "false"
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
          volumeMounts:
            - name: device-plugin
              mountPath: /var/lib/kubelet/device-plugins
      volumes:
        - name: device-plugin
          hostPath:
            path: /var/lib/kubelet/device-plugins
EOF

echo "== 확인 (Allocatable에 nvidia.com/gpu 있어야 함) =="
sleep 5
kubectl -n kube-system get pods -l name=nvidia-device-plugin-ds -o wide

echo "완료: nvidia-device-plugin 설치"
