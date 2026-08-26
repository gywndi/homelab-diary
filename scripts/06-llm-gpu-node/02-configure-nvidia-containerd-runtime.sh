#!/bin/bash
# containerd의 기본 런타임을 nvidia로 설정
#
# 이 노드는 GPU 전용으로 taint를 걸어 GPU 요청 파드만 스케줄되게 할
# 것이므로, RuntimeClass를 따로 안 만들고 바로 기본값으로 지정한다.
#
# 사용법: sudo ./02-configure-nvidia-containerd-runtime.sh
# 사전 조건: nvidia-container-toolkit 설치돼 있어야 함

set -euo pipefail

nvidia-ctk runtime configure --runtime=containerd --set-as-default
systemctl restart containerd

echo "== 확인 =="
systemctl is-active containerd
containerd config dump 2>/dev/null | grep default_runtime_name

echo "완료: containerd 기본 런타임을 nvidia로 설정"
