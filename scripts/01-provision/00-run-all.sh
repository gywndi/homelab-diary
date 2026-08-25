#!/bin/bash
# 전체 초기 설정 실행 (패키지 업데이트 -> 타임존 -> 방화벽 -> 데이터 디스크)
#
# 사용법: sudo ./00-run-all.sh /dev/sdaX
#   10.5.5.8, 10.5.5.9 모두 : sudo ./00-run-all.sh /dev/sda1

set -euo pipefail

DEVICE="${1:-}"
if [[ -z "$DEVICE" ]]; then
  echo "사용법: $0 /dev/sdaX" >&2
  exit 1
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$DIR/02-system-update.sh"
"$DIR/03-timezone.sh"
"$DIR/04-firewall.sh"
"$DIR/01-format-mount-data.sh" "$DEVICE"

echo "===================================="
echo "모든 초기 설정 완료"
echo "===================================="
