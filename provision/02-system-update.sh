#!/bin/bash
# 기본 패키지 업데이트 및 필수 유틸 설치
#
# 사용법: sudo ./02-system-update.sh

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "== apt update / upgrade =="
apt-get update -y
apt-get upgrade -y
apt-get dist-upgrade -y

echo "== 기본 유틸 설치 =="
apt-get install -y \
  curl \
  wget \
  vim \
  git \
  htop \
  net-tools \
  ca-certificates \
  gnupg \
  lsb-release \
  chrony \
  xfsprogs \
  ufw

echo "== 불필요 패키지 정리 =="
apt-get autoremove -y
apt-get autoclean -y

if [ -f /var/run/reboot-required ]; then
  echo "!! 커널 업데이트 등으로 재부팅이 필요합니다 (sudo reboot) !!"
fi

echo "완료: 패키지 업데이트"
