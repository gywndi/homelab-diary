#!/bin/bash
# GPU 노드에 라벨/taint를 걸어서 GPU를 요청하는 파드만 스케줄되게 한다
#
# 사용법: ./06-label-and-taint-gpu-node.sh <노드 이름>
#   예: ./06-label-and-taint-gpu-node.sh llm001

set -euo pipefail

NODE="${1:-}"
if [[ -z "$NODE" ]]; then
  echo "사용법: $0 <노드 이름>" >&2
  exit 1
fi

kubectl label node "$NODE" nvidia.com/gpu=true --overwrite
kubectl taint node "$NODE" nvidia.com/gpu=present:NoSchedule --overwrite

echo "== 확인 =="
kubectl describe node "$NODE" | grep -A3 Taints

echo "완료: $NODE 라벨/taint 설정"
