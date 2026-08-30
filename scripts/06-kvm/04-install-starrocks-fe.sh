#!/bin/bash
# StarRocks FE를 이 VM에 베어메탈(systemd)로 설치한다. 클러스터당 1대에서만 실행.
# k8s 버전과 달리 컨테이너 이미지가 아니라 공식 바이너리 tarball을 그대로 쓴다.
#
# 사전 조건: VM이 4GB RAM 기준(그보다 크면 JAVA_OPTS의 -Xmx1536m을 올릴 것)
# 사용법: sudo ./04-install-starrocks-fe.sh <이 VM의 IP>
#   예: sudo ./04-install-starrocks-fe.sh 10.5.5.52

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

echo "== StarRocks 바이너리 다운로드 + 설치 =="
mkdir -p /opt/starrocks
curl -fL -o /tmp/starrocks.tar.gz "$URL"
tar -xzf /tmp/starrocks.tar.gz -C /opt/starrocks --strip-components=1
rm /tmp/starrocks.tar.gz
chown -R chan:chan /opt/starrocks

echo "== fe.conf 조정 (4GB VM에 맞춰 힙 축소 + 이 노드 IP 고정) =="
sed -i 's/-Xmx8192m/-Xmx1536m/' /opt/starrocks/fe/conf/fe.conf
cat >> /opt/starrocks/fe/conf/fe.conf <<EOF

# 이 VM(4GB RAM)에 맞춰 힙 축소, 단일 NIC이라도 IP를 명시해 바인딩 모호성 제거
priority_networks = ${IP}/32
EOF

echo "== systemd 유닛 등록 =="
cat > /etc/systemd/system/starrocks-fe.service <<'EOF'
[Unit]
Description=StarRocks Frontend
After=network.target

[Service]
Type=simple
User=chan
WorkingDirectory=/opt/starrocks/fe
ExecStart=/opt/starrocks/fe/bin/start_fe.sh
ExecStop=/opt/starrocks/fe/bin/stop_fe.sh
Restart=on-failure
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now starrocks-fe

echo "== 기동 대기 (query port 9030) =="
until mysql -h 127.0.0.1 -P 9030 -u root -e "SELECT 1;" >/dev/null 2>&1; do
  sleep 3
done

echo "완료: FE 기동됨. mysql -h ${IP} -P 9030 -u root 로 접속 가능."
