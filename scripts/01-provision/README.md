# 서버 초기 프로비저닝

우분투를 새로 설치한 k8s 클러스터 후보 노드 2대의 기본 설정 스크립트 모음입니다.

## 목적

새로 설치한 서버는 SSH는 되지만 sudo에 비밀번호를 요구해서 그 상태로는 원격 자동화가 불가능하다. 계정에 NOPASSWD sudo 권한을 열어 이후 단계를 전부 스크립트로 처리할 수 있게 만들고, 그 위에 패키지 업데이트·타임존·방화벽(기본 인바운드 차단)·데이터 디스크 마운트까지 baseline을 갖춘다.

## 대상 서버

| IP        | 호스트명 | OS               | 데이터 디스크 |
|-----------|----------|------------------|----------------|
| 10.5.5.8  | chan08   | Ubuntu 24.04 LTS | `/dev/sda1` (디스크 전체 단일 파티션) |
| 10.5.5.9  | chan09   | Ubuntu 24.04 LTS | `/dev/sda1` (디스크 전체 단일 파티션) |

- 접근: 단일 작업 계정, SSH 키 인증 (비밀번호 없이 접속)
- sudo: 부트스트랩 스크립트가 만든 `/etc/sudoers.d/90-chan-nopasswd`로 비밀번호 없이 sudo 가능
- 관리 서버(작업 실행 위치) IP: 10.5.5.7 — 방화벽 규칙에서 이 대역(10.5.5.0/24)만 허용하므로 락아웃되지 않음

## 스크립트 목록 (실행 순서)

전부 `sudo`로 실행해야 합니다. 각 서버 `~/provision/`에도 동일한 스크립트가 복사되어 있습니다.

### 0. `bootstrap-sudoers.sh` — NOPASSWD sudo 권한 부여 (사람이 콘솔에 직접 로그인해서 최초 1회 실행)
이 시점까진 sudo가 비밀번호를 요구해서 SSH로 원격 자동 실행이 불가능하다. 이후 모든 명령은 이 권한을 전제로 원격에서 돈다.
```bash
echo "chan ALL=(ALL) NOPASSWD:ALL" | sudo visudo -f /etc/sudoers.d/90-chan-nopasswd
sudo chmod 0440 /etc/sudoers.d/90-chan-nopasswd
sudo visudo -c
```

### 1. `02-system-update.sh` — 패키지 전체 업데이트 + 기본 유틸 설치
```bash
sudo apt-get update -y && sudo apt-get upgrade -y && sudo apt-get dist-upgrade -y
sudo apt-get install -y curl wget vim git htop net-tools ca-certificates gnupg lsb-release chrony xfsprogs ufw
sudo apt-get autoremove -y && sudo apt-get autoclean -y
```

### 2. `03-timezone.sh` — 타임존을 Asia/Seoul로 통일
```bash
sudo timedatectl set-timezone Asia/Seoul
sudo systemctl enable --now chrony
```

### 3. `04-firewall.sh` — UFW 기본 정책 적용
```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 10.5.5.0/24 to any port 22 proto tcp
sudo ufw allow from 10.5.5.0/24 to any port 6443 proto tcp
# ... 나머지 포트는 아래 "방화벽 정책" 표 전체 참고
sudo ufw --force enable
```

### 4. `01-format-mount-data.sh` — 데이터 디스크 포맷 + `/data` 마운트 (양쪽 서버 모두 `/dev/sda1`)
```bash
sudo mkfs.xfs -f /dev/sda1
sudo blkid -s UUID -o value /dev/sda1
# 출력된 UUID를 /etc/fstab에 한 줄 추가 (예: UUID=2e346eca-8a4d-4d59-8897-4b5d84aefdc3  /data  xfs  defaults  0  2)
sudo mount -a
```

### 5. `05-firewall-stage1.sh` — 방화벽 Stage 1 재정리
```bash
sudo ufw allow from 10.5.5.0/24 to any port 3306 proto tcp
sudo ufw allow from 10.5.5.0/24 proto vrrp
sudo ufw delete allow from 10.5.5.0/24 to any port 179 proto tcp
sudo ufw delete allow from 10.5.5.0/24 to any port 4789 proto udp
```

### (일괄 실행) `00-run-all.sh`
`02-system-update.sh` → `03-timezone.sh` → `04-firewall.sh` → `01-format-mount-data.sh`를 순서대로 그대로 호출하는 래퍼.

## 방화벽 정책 (`04-firewall.sh`)

기본 정책: **인바운드 전체 차단**, 아웃바운드 전체 허용. 인바운드는 내부 대역 `10.5.5.0/24`에서만 아래 포트를 허용합니다.

| 포트 | 프로토콜 | 용도 |
|------|----------|------|
| 22 | tcp | SSH |
| 6443 | tcp | Kubernetes API server |
| 2379-2380 | tcp | etcd |
| 10250 | tcp | kubelet API |
| 10257 | tcp | kube-controller-manager (secure) |
| 10259 | tcp | kube-scheduler (secure) |
| 30000-32767 | tcp | NodePort Services |
| 8472 | udp | Flannel VXLAN |
| 3306 | tcp | MySQL |
| vrrp | - | keepalived (MySQL VIP 페일오버) |

> `05-firewall-stage1.sh`로 Stage 1 확정 사항(CNI=Flannel, MySQL, keepalived) 반영 완료.
> Calico 미사용 확정으로 179/tcp, 4789/udp는 제거됨.

상태 확인: `sudo ufw status verbose`

## 데이터 디스크 (`01-format-mount-data.sh`)

- 대상 디바이스는 서버마다 다르므로 **반드시 인자로 전달**해야 합니다 (하드코딩 안 함).
- XFS로 강제 포맷(`mkfs.xfs -f`) 하므로 **기존 데이터는 삭제**됩니다. 실행 전 `lsblk`, `blkid`로 대상 디바이스를 재확인할 것.
- 포맷 후 `blkid`로 UUID를 가져와 `/etc/fstab`에 추가하므로 재부팅해도 자동 마운트됩니다.
- `/etc/fstab`은 실행 시각이 포함된 타임스탬프로 백업됩니다 (`/etc/fstab.bak.YYYYmmddHHMMSS`).
- 포맷 직후 `df -h`에는 약 18G가 "사용 중"으로 표시되는데, 실제 파일이 아니라 Ubuntu 24.04 `mkfs.xfs` 기본 옵션(`reflink=1`, `rmapbt=1`)의 메타데이터 예약 공간입니다. 정상입니다.

## 검증 이력

2026-08-24 두 서버 모두 아래 순서로 적용 및 재부팅 후 검증 완료:
1. SSH 키 인증 확인
2. sudoers NOPASSWD 적용
3. `02-system-update.sh` → `03-timezone.sh` → `04-firewall.sh` → `01-format-mount-data.sh` 순 실행
4. 커널 업데이트로 인한 재부팅 수행, 재부팅 후 타임존/방화벽/`/data` 마운트/sudo 모두 정상 유지 확인
