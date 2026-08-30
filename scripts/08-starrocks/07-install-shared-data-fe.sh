#!/bin/bash
# StarRocks 2번째 FE(run_mode=shared_data)를 이 VM에 설치한다.
# 기존 FE(04-install-starrocks-fe.sh, shared-nothing)와 완전히 독립된 인스턴스다 —
# run_mode는 클러스터가 처음 뜰 때 고정되고 이후 못 바꾸므로, 같은 FE에서
# shared-data를 시연할 수 없다. 포트를 전부 분리해 같은 VM에 공존시킨다.
#
# 사전 조건: 06-create-shared-data-rgw-user-and-bucket.sh로 RGW 유저/버킷 준비
# 사용법: sudo ./07-install-shared-data-fe.sh <이 VM의 IP> <RGW ACCESS_KEY> <RGW SECRET_KEY>
#   예: sudo ./07-install-shared-data-fe.sh 10.5.5.52 <ACCESS_KEY> <SECRET_KEY>

set -euo pipefail

IP="${1:-}"
ACCESS_KEY="${2:-}"
SECRET_KEY="${3:-}"
if [[ -z "$IP" || -z "$ACCESS_KEY" || -z "$SECRET_KEY" ]]; then
  echo "사용법: $0 <이 VM의 IP> <RGW ACCESS_KEY> <RGW SECRET_KEY>" >&2
  exit 1
fi

VERSION="4.1.4"
URL="https://releases.starrocks.io/starrocks/StarRocks-${VERSION}-ubuntu-amd64.tar.gz"

echo "== StarRocks 바이너리 새로 다운로드 (기존 FE와 완전히 별도 디렉터리) =="
mkdir -p /opt/starrocks-sd
curl -fL -o /tmp/starrocks-sd.tar.gz "$URL"
tar -xzf /tmp/starrocks-sd.tar.gz -C /opt/starrocks-sd --strip-components=1
rm /tmp/starrocks-sd.tar.gz
chown -R chan:chan /opt/starrocks-sd

echo "== fe.conf 조정 (힙 축소 + 포트 전부 분리 + shared_data 설정) =="
sed -i 's/-Xmx8192m/-Xmx1024m/' /opt/starrocks-sd/fe/conf/fe.conf
cat >> /opt/starrocks-sd/fe/conf/fe.conf <<EOF

# 기존 FE(04번)와 같은 VM에 공존하므로 모든 포트를 분리
http_port = 8031
rpc_port = 9021
query_port = 9031
edit_log_port = 9011
priority_networks = ${IP}/32

# shared-data: 로컬 디스크가 아니라 RGW(S3 호환)에 데이터를 둔다
run_mode = shared_data
cloud_native_storage_type = S3
cloud_native_meta_port = 6091
enable_load_volume_from_conf = true
tablet_create_timeout_second = 60
aws_s3_path = baremetal-starrocks-storage
aws_s3_region = default
aws_s3_endpoint = http://ceph.home:7480
aws_s3_use_aws_sdk_default_behavior = false
aws_s3_use_instance_profile = false
aws_s3_access_key = ${ACCESS_KEY}
aws_s3_secret_key = ${SECRET_KEY}
EOF

echo "== systemd 유닛 등록 (기존 starrocks-fe와 별개 유닛) =="
cat > /etc/systemd/system/starrocks-sd-fe.service <<'EOF'
[Unit]
Description=StarRocks Frontend (shared-data)
After=network.target

[Service]
Type=simple
User=chan
WorkingDirectory=/opt/starrocks-sd/fe
ExecStart=/opt/starrocks-sd/fe/bin/start_fe.sh
ExecStop=/opt/starrocks-sd/fe/bin/stop_fe.sh
Restart=on-failure
RestartSec=10
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now starrocks-sd-fe

echo "== 기동 대기 (query port 9031) =="
until mysql -h 127.0.0.1 -P 9031 -u root -e "SELECT 1;" >/dev/null 2>&1; do
  sleep 3
done

echo "완료: shared-data FE 기동됨. mysql -h ${IP} -P 9031 -u root 로 접속 가능."
