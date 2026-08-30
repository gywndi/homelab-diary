#!/bin/bash
# cephadm이 Ceph 데몬을 담을 컨테이너 런타임(podman) 설치.
#
# 사용법: 3노드(chan08/chan09/llm001) 각각에서 실행
#   sudo ./13-install-podman.sh

set -euo pipefail

apt-get update -y
apt-get install -y podman
podman --version
