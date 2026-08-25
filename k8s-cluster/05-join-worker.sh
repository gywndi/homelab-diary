#!/bin/bash
# 워커 노드 조인 (chan09 전용)
#
# 사용법: sudo ./05-join-worker.sh
# 사전 조건: chan08의 /home/chan/join-command.sh 를 이 서버 ~/join-command.sh 로 복사해둘 것

set -euo pipefail

JOIN_SCRIPT="/home/chan/join-command.sh"

if [[ ! -f "$JOIN_SCRIPT" ]]; then
  echo "오류: $JOIN_SCRIPT 가 없습니다. chan08에서 생성된 join-command.sh를 먼저 복사하세요." >&2
  exit 1
fi

bash "$JOIN_SCRIPT"

echo "완료: 워커 노드 join"
