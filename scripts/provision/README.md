# 서버 초기 프로비저닝

우분투를 새로 설치한 k8s 클러스터 후보 노드 2대의 기본 설정 스크립트 모음입니다.

## 대상 서버

| IP        | 호스트명 | OS               | 계정 | 데이터 디스크 |
|-----------|----------|------------------|------|----------------|
| 10.5.5.8  | chan08   | Ubuntu 24.04 LTS | chan | `/dev/sda2` (1M 예약 파티션 `sda1` 존재) |
| 10.5.5.9  | chan09   | Ubuntu 24.04 LTS | chan | `/dev/sda1` (디스크 전체 단일 파티션) |

- 접근: `chan` 계정, SSH 키 인증 (비밀번호 없이 접속)
- sudo: `/etc/sudoers.d/90-chan-nopasswd` 에 `chan ALL=(ALL) NOPASSWD:ALL` 적용됨 (비밀번호 없이 sudo 가능)
- 관리 서버(작업 실행 위치) IP: 10.5.5.7 — 방화벽 규칙에서 이 대역(10.5.5.0/24)만 허용하므로 락아웃되지 않음

## 스크립트 목록 (실행 순서)

전부 `sudo`로 실행해야 합니다. 각 서버 `~/provision/`에도 동일한 스크립트가 복사되어 있습니다.

| 순서 | 파일 | 내용 |
|------|------|------|
| 0 | `bootstrap-sudoers.sh` | **사람이 직접 최초 1회 실행.** chan 계정에 NOPASSWD sudo 권한 부여. 이 시점까진 sudo가 비밀번호를 요구해서 원격 자동 실행이 불가능함 |
| 1 | `02-system-update.sh` | `apt update/upgrade/dist-upgrade`, 기본 유틸(curl, vim, git, htop, chrony, xfsprogs, ufw 등) 설치, 불필요 패키지 정리 |
| 2 | `03-timezone.sh` | 타임존을 `Asia/Seoul`(KST)로 변경, chrony(NTP) 활성화 |
| 3 | `04-firewall.sh` | UFW 방화벽 설정 (아래 "방화벽 정책" 참고) |
| 4 | `01-format-mount-data.sh` | 지정한 디스크를 XFS로 포맷하고 `/data`에 마운트, `/etc/fstab`에 UUID로 등록 |
| 5 | `05-firewall-stage1.sh` | MySQL/keepalived 포트 추가, 안 쓰는 Calico 포트 제거 (Stage 1 방화벽 재정리) |
| - | `00-run-all.sh` | `bootstrap-sudoers.sh` 이후 1~4를 순서대로 한 번에 실행하는 래퍼. `sudo ./00-run-all.sh /dev/sdaX` |

### 사용 예시

```bash
# 10.5.5.8
sudo ~/provision/00-run-all.sh /dev/sda2

# 10.5.5.9
sudo ~/provision/00-run-all.sh /dev/sda1
```

개별 실행도 가능합니다 (`01-format-mount-data.sh`만 디바이스 경로 인자 필요):

```bash
sudo ~/provision/01-format-mount-data.sh /dev/sda2
```

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
