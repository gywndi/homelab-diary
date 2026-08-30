#!/bin/bash
# StarRocks CN(Compute Node)을 이 VM에 설치한다. 07번(shared-data FE)에 등록해서 쓴다.
# 공식 tarball엔 cn/ 디렉터리가 따로 없다 — CN은 BE와 바이너리가 완전히 같고,
# be/bin/start_cn.sh와 be/conf/cn.conf로 이미 포함돼 있다. 기존 BE(05번) 인스턴스와
# 섞이지 않도록 별도 디렉터리(cn/)로 복사해서 쓴다.
#
# 사전 조건: 07-install-shared-data-fe.sh로 shared-data FE가 떠 있을 것
# 사용법: sudo ./08-install-cn.sh <이 VM의 IP>
#   예: sudo ./08-install-cn.sh 10.5.5.52

set -euo pipefail

IP="${1:-}"
if [[ -z "$IP" ]]; then
  echo "사용법: $0 <이 VM의 IP>" >&2
  exit 1
fi

VERSION="4.1.4"
URL="https://releases.starrocks.io/starrocks/StarRocks-${VERSION}-ubuntu-amd64.tar.gz"

echo "== 바이너리 다운로드 후 be/ 디렉터리를 cn/으로 복사 (기존 BE 인스턴스와 분리) =="
mkdir -p /tmp/starrocks-cn-extract
curl -fL -o /tmp/starrocks-cn.tar.gz "$URL"
tar -xzf /tmp/starrocks-cn.tar.gz -C /tmp/starrocks-cn-extract --strip-components=1
mkdir -p /opt/starrocks-sd
cp -r /tmp/starrocks-cn-extract/be /opt/starrocks-sd/cn
rm -rf /tmp/starrocks-cn-extract /tmp/starrocks-cn.tar.gz
chown -R chan:chan /opt/starrocks-sd/cn

echo "== cn.conf 조정 (기존 BE와 포트 전부 분리) =="
cat >> /opt/starrocks-sd/cn/conf/cn.conf <<EOF

be_port = 9061
brpc_port = 8061
heartbeat_service_port = 9051
starlet_port = 9071
priority_networks = ${IP}/32
EOF

echo "== systemd 유닛 등록 =="
cat > /etc/systemd/system/starrocks-cn.service <<'EOF'
[Unit]
Description=StarRocks Compute Node
After=network.target

[Service]
Type=simple
User=chan
WorkingDirectory=/opt/starrocks-sd/cn
ExecStart=/opt/starrocks-sd/cn/bin/start_cn.sh
ExecStop=/opt/starrocks-sd/cn/bin/stop_cn.sh
Restart=on-failure
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now starrocks-cn

echo "완료: CN 기동됨. shared-data FE에서 ALTER SYSTEM ADD COMPUTE NODE '${IP}:9051'; 로 등록할 것."
