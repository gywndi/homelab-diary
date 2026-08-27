#!/bin/bash
# 워커 노드 조인 (chan09 전용)
#
# 사용법: sudo ./07-join-worker.sh
# 사전 조건: chan08의 join-command.sh를 이 서버의 실행 계정 홈 디렉터리(~/join-command.sh)로 복사해둘 것

set -euo pipefail

TARGET_USER="${SUDO_USER:-$(whoami)}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
JOIN_SCRIPT="$TARGET_HOME/join-command.sh"

if [[ ! -f "$JOIN_SCRIPT" ]]; then
  echo "오류: $JOIN_SCRIPT 가 없습니다. chan08에서 생성된 join-command.sh를 먼저 복사하세요." >&2
  exit 1
fi

bash "$JOIN_SCRIPT"

echo "완료: 워커 노드 join"
