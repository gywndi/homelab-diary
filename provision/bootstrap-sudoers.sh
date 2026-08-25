#!/bin/bash
# 최초 1회 부트스트랩: chan 계정에 비밀번호 없는 sudo 권한을 부여한다.
#
# 이 시점에는 아직 sudo가 비밀번호를 요구하는 상태이므로, SSH로 원격
# 자동 실행이 불가능하다. 반드시 콘솔/SSH로 직접 로그인해서 사람이
# 실행해야 한다 (이후의 모든 스크립트는 이 권한을 전제로 원격에서 자동 실행됨).
#
# 사용법: (서버에 직접 로그인한 상태에서)
#   ./bootstrap-sudoers.sh

set -euo pipefail

echo "chan ALL=(ALL) NOPASSWD:ALL" | sudo visudo -f /etc/sudoers.d/90-chan-nopasswd
sudo chmod 0440 /etc/sudoers.d/90-chan-nopasswd
sudo visudo -c

echo "== 확인 =="
sudo -n true && echo "NOPASSWD sudo OK"
