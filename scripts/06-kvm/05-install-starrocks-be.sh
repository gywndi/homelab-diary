#!/bin/bash
# StarRocks BE를 이 VM에 베어메탈(systemd)로 설치한다. 클러스터의 모든 VM에서 실행.
#
# 사용법: sudo ./05-install-starrocks-be.sh <이 VM의 IP>
#   예: sudo ./05-install-starrocks-be.sh 10.5.5.52

set -euo pipefail

IP="${1:-}"
if [[ -z "$IP" ]]; then
  echo "사용법: $0 <이 VM의 IP>" >&2
  exit 1
fi

VERSION="4.1.4"
URL="https://releases.starrocks.io/starrocks/StarRocks-${VERSION}-ubuntu-amd64.tar.gz"

echo "== Java 설치 =="
apt-get update -y
apt-get install -y openjdk-17-jdk-headless

echo "== StarRocks 바이너리 다운로드 + 설치 (이미 있으면 건너뜀 — FE와 같은 VM일 수 있음) =="
if [[ ! -d /opt/starrocks/be ]]; then
  mkdir -p /opt/starrocks
  curl -fL -o /tmp/starrocks.tar.gz "$URL"
  tar -xzf /tmp/starrocks.tar.gz -C /opt/starrocks --strip-components=1
  rm /tmp/starrocks.tar.gz
  chown -R chan:chan /opt/starrocks
fi

echo "== be.conf 조정 (이 노드 IP 고정) =="
cat >> /opt/starrocks/be/conf/be.conf <<EOF

priority_networks = ${IP}/32
EOF

echo "== systemd 유닛 등록 =="
cat > /etc/systemd/system/starrocks-be.service <<'EOF'
[Unit]
Description=StarRocks Backend
After=network.target

[Service]
Type=simple
User=chan
WorkingDirectory=/opt/starrocks/be
ExecStart=/opt/starrocks/be/bin/start_be.sh
ExecStop=/opt/starrocks/be/bin/stop_be.sh
Restart=on-failure
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now starrocks-be

echo "완료: BE 기동됨. FE에서 ALTER SYSTEM ADD BACKEND '${IP}:9050'; 로 등록할 것."
