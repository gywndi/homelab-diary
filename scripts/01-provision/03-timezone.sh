#!/bin/bash
# 타임존을 Asia/Seoul(KST)로 설정
#
# 사용법: sudo ./03-timezone.sh

set -euo pipefail

TZ="Asia/Seoul"

echo "== 타임존을 $TZ 로 설정 =="
timedatectl set-timezone "$TZ"

echo "== chrony(NTP) 활성화 =="
systemctl enable --now chrony 2>/dev/null || systemctl enable --now chronyd

echo "== 결과 확인 =="
timedatectl status

echo "완료: 타임존 $TZ"
