#!/bin/bash
# cephadm 설치 + 클러스터 부트스트랩(mon+mgr) — chan08(관리 노드) 1회만 실행.
# 부트스트랩 직후 auth_allowed_ciphers를 레거시(aes) 포함으로 되돌린다 —
# Squid(19.x)는 신규 클러스터를 새 32바이트 암호(aes256k)만 허용하도록 만드는데,
# 이러면 커널 krbd(리눅스 커널 내장 RBD 드라이버)가 그 키를 못 읽는다
# (아래 "알려진 이슈" 참고). 이 스텝을 건너뛰면 이후 만드는 모든 cephx 키가
# krbd와 호환 안 된다.
#
# 사용법: sudo ./14-cephadm-bootstrap.sh <mon IP, 예: 10.5.5.8>

set -euo pipefail

MON_IP="${1:-}"
if [[ -z "$MON_IP" ]]; then
  echo "사용법: $0 <mon IP>" >&2
  exit 1
fi

echo "== cephadm 설치 스크립트 다운로드(Squid 릴리스) =="
curl --silent --remote-name --location https://download.ceph.com/rpm-squid/el9/noarch/cephadm
chmod +x cephadm

echo "== 호스트 사전 점검 =="
./cephadm check-host

echo "== 클러스터 부트스트랩(mon+mgr) =="
DASH_PW=$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)
./cephadm bootstrap \
  --mon-ip "$MON_IP" \
  --cluster-network 10.5.5.0/24 \
  --allow-fqdn-hostname \
  --initial-dashboard-user admin \
  --initial-dashboard-password "$DASH_PW" \
  --dashboard-password-noupdate
echo "대시보드 초기 비밀번호(재설정 전까지만 유효): $DASH_PW"

echo "== cephadm을 시스템 PATH에 설치(스크립트에서 상대경로 './cephadm' 안 쓰기 위함) =="
cp ./cephadm /usr/local/bin/cephadm
chmod +x /usr/local/bin/cephadm

echo "== ceph-common CLI 설치 시도(참고용 — Ubuntu noble엔 Ceph 공식 repo가 없어 apt 기본 저장소 버전이 깔림) =="
echo "   버전이 안 맞으면 keyring 파싱이 깨질 수 있다. 이후 모든 ceph 명령은 'cephadm shell -- ceph ...'로 실행할 것."
cephadm install ceph-common || true

echo "== 레거시 cephx 키(aes, krbd 호환) 허용 =="
cephadm shell -- ceph mon set auth_allowed_ciphers "aes, aes256k"
cephadm shell -- ceph mon set auth_preferred_cipher aes

echo "완료: mon+mgr 부트스트랩. 다음 단계: 14-cephadm-add-host.sh로 나머지 노드 추가"
