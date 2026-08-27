#!/bin/bash
# GPU 노드에 라벨을 걸어서 device-plugin의 nodeSelector가 찾을 수 있게 한다
#
# taint는 걸지 않는다 — GPU를 요청하는 파드는 nvidia.com/gpu 리소스를
# 실제로 가진 노드가 여기뿐이라 taint 없이도 자동으로 이 노드로만
# 스케줄되고, taint를 걸면 오히려 일반 워크로드가 이 노드를 못 쓰게
# 막는 손해만 있다.
#
# 사용법: ./04-label-gpu-node.sh <노드 이름>
#   예: ./04-label-gpu-node.sh llm001

set -euo pipefail

NODE="${1:-}"
if [[ -z "$NODE" ]]; then
  echo "사용법: $0 <노드 이름>" >&2
  exit 1
fi

kubectl label node "$NODE" nvidia.com/gpu=true --overwrite

echo "== 확인 =="
kubectl get node "$NODE" --show-labels | grep -o 'nvidia.com/gpu=true'

echo "완료: $NODE 라벨 설정"
