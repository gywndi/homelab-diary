#!/bin/bash
# NVIDIA 드라이버를 완전히 제거하고 지정한 버전으로 재설치
#
# ubuntu-drivers devices로 recommended 드라이버를 확인한 뒤 그 패키지명을
# 인자로 넘긴다. 재부팅해야 새 커널 모듈이 올라온다.
#
# 사용법: sudo ./01-reinstall-nvidia-driver.sh <드라이버 패키지명>
#   예: ./01-reinstall-nvidia-driver.sh nvidia-driver-595-open

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

DRIVER_PKG="${1:-}"
if [[ -z "$DRIVER_PKG" ]]; then
  echo "사용법: $0 <드라이버 패키지명 (예: nvidia-driver-595-open)>" >&2
  echo "확인: ubuntu-drivers devices" >&2
  exit 1
fi

echo "== 기존 드라이버 hold 해제 =="
apt-mark showhold | grep '^nvidia-driver-' | xargs -r apt-mark unhold

echo "== 기존 드라이버 관련 패키지 purge (cuda/cudnn/container-toolkit은 유지) =="
apt-get purge -y --allow-change-held-packages \
  'nvidia-driver-*' 'nvidia-dkms-*' 'nvidia-utils-*' 'xserver-xorg-video-nvidia-*' \
  'libnvidia-cfg1-*' 'libnvidia-common-*' 'libnvidia-compute-*' 'libnvidia-decode-*' \
  'libnvidia-encode-*' 'libnvidia-extra-*' 'libnvidia-fbc1-*' 'libnvidia-gl-*' \
  'nvidia-compute-utils-*' || true

apt-get autoremove -y

echo "== 신규 드라이버 설치: $DRIVER_PKG =="
apt-get update -y
apt-get install -y "$DRIVER_PKG"
apt-mark hold "$DRIVER_PKG"

echo "완료: 드라이버 재설치. 재부팅 필요 (sudo reboot), 이후 nvidia-smi로 확인"
