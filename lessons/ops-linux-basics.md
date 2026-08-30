# 리눅스 기본 상식 (운영 명령어를 이해하기 위한 최소 지식)

[k8s](ops-k8s.md)/[Ceph](ops-ceph.md)/[StarRocks](08-4-starrocks-ops.md) 운영 문서에 나오는 명령들이 실제로 무엇을 하는지 이해하려면 필요한 기초. 각 서비스 자체 지식이 아니라, 그 아래 깔린 우분투 서버 운영의 공통 문법이다. 이 저장소 전체에서 대상 OS는 **Ubuntu 24.04 LTS**.

## systemd — 서비스 시작/중지/상태

리눅스에서 백그라운드로 계속 떠있는 프로그램(서비스, 데몬)을 관리하는 표준 도구. `keepalived`, `mysql`, `containerd`, `chrony` 등 이 저장소에서 다루는 거의 모든 서비스가 systemd 유닛으로 등록되어 있다.

```bash
# 지금 상태 (active/inactive, 최근 로그 일부, PID)
sudo systemctl status <서비스명>

# 시작 / 중지 / 재시작(중지 후 시작) / reload(설정만 다시 읽음, 무중단인 경우가 많음)
sudo systemctl start <서비스명>
sudo systemctl stop <서비스명>
sudo systemctl restart <서비스명>
sudo systemctl reload <서비스명>

# 부팅 시 자동 시작 여부 설정 (--now를 붙이면 지금 바로 시작도 같이)
sudo systemctl enable --now <서비스명>
sudo systemctl disable <서비스명>

# 이 서비스가 지금 실행 중인지 / 부팅 시 자동 시작으로 설정돼 있는지만 짧게 확인
systemctl is-active <서비스명>
systemctl is-enabled <서비스명>
```

## journalctl — 로그 보기

systemd가 관리하는 서비스의 로그는 전통적인 `/var/log/*.log` 파일이 아니라 journald라는 바이너리 로그로 모인다. `journalctl`로 조회한다.

```bash
# 특정 서비스 로그, 최신이 아래로 오는 순서
sudo journalctl -u <서비스명>

# 실시간으로 따라가며 보기 (Ctrl+C로 종료)
sudo journalctl -u <서비스명> -f

# 최근 N분/시간만
sudo journalctl -u <서비스명> --since '10 min ago'

# 커널 메시지만 (방화벽 BLOCK 로그, 디스크/드라이버 에러 등)
sudo journalctl -k

# 특정 패턴만 걸러보기
sudo journalctl -k | grep 'UFW BLOCK'
```

## UFW — 방화벽

Ubuntu의 iptables(리눅스 커널 방화벽)를 다루기 쉽게 감싼 도구. 이 저장소의 모든 노드가 "기본은 인바운드 전체 차단, 필요한 포트만 내부망(`10.5.5.0/24`)에 허용"하는 정책을 쓴다([`01-provision.md`](01-provision.md#방화벽-정책) 참고).

```bash
# 현재 규칙 전체 (번호 포함 — delete 할 때 번호로 지정 가능)
sudo ufw status verbose
sudo ufw status numbered

# 특정 대역에서 특정 포트만 허용 (comment는 나중에 이유를 까먹지 않기 위한 메모)
sudo ufw allow from 10.5.5.0/24 to any port 6443 proto tcp comment 'k8s API'

# 인터넷 전체에서 허용 (from 생략 = anywhere, ingress의 80/443처럼 외부 트래픽을 받아야 할 때만)
sudo ufw allow 443/tcp

# 규칙 제거 (번호로, 또는 추가할 때와 동일한 문법으로)
sudo ufw delete <번호>
sudo ufw delete allow from 10.5.5.0/24 to any port 6443 proto tcp

# 설정 반영
sudo ufw reload
```
UFW는 "인바운드(이 서버로 들어오는 트래픽)" 규칙과 "FORWARD(이 서버를 그냥 거쳐가는 트래픽 — 라우터 역할)" 규칙이 분리돼 있다. `/etc/default/ufw`의 `DEFAULT_FORWARD_POLICY`가 기본 `DROP`인데, k8s 파드 네트워크처럼 이 서버를 경유해서 라우팅되는 트래픽은 인바운드 규칙과 무관하게 이 값의 영향을 받는다 — [`02-k8s-cluster.md`의 관련 알려진 이슈](02-k8s-cluster.md#알려진-이슈-ufw가-pod-네트워크를-막음) 참고.

**주의**: `iptables -F`처럼 iptables를 직접 조작하면 UFW가 애써 걸어둔 ALLOW 규칙만 사라지고 DROP 기본 정책은 그대로 남아 SSH까지 완전히 막힐 수 있다. UFW를 쓰는 노드에서는 반드시 `ufw` 명령만 사용한다.

## 디스크/파티션/마운트

```bash
# 지금 연결된 디스크와 파티션 트리 (크기, 마운트 위치)
lsblk

# 파티션의 UUID/파일시스템 종류 확인 (fstab에 UUID로 등록할 때 필요)
sudo blkid

# 파티션 나누기 (대화형 fdisk 대신 스크립트에서 쓰기 좋은 non-interactive 도구)
sudo parted -s /dev/sda mklabel msdos
sudo parted -s /dev/sda mkpart primary 1MiB 500GB
sudo partprobe /dev/sda   # 커널에게 파티션 테이블이 바뀌었다고 알림

# 포맷 (XFS는 이 저장소 전체의 기본 데이터 파티션 포맷)
sudo mkfs.xfs -f /dev/sda2

# 지금 이 순간만 마운트 (재부팅하면 사라짐)
sudo mount /dev/sda2 /data

# 재부팅해도 유지되도록 /etc/fstab에 등록 (디바이스명 대신 UUID 사용 — 재부팅 시 디바이스 순서가 바뀔 수 있어서)
echo 'UUID=<blkid로 확인한 값>  /data  xfs  defaults  0  2' | sudo tee -a /etc/fstab

# fstab에 방금 추가한 항목을 재부팅 없이 즉시 마운트
sudo mount -a

# 지금 마운트된 파티션들의 용량 (df -h가 "사람이 읽기 좋은" 단위)
df -h
```

## LVM — 파티션을 논리 볼륨으로 감싸기

Ceph의 `ceph orch daemon add osd`처럼, 일부 도구는 raw 파티션을 직접 못 받고 LVM(Logical Volume Manager) 논리 볼륨만 받는다. LVM은 물리 파티션(PV) 위에 볼륨 그룹(VG)을 만들고, 그 안에서 실제 쓰는 논리 볼륨(LV)을 잘라내는 계층 구조다.

```bash
# 파티션을 물리 볼륨으로 등록
sudo pvcreate /dev/sda1

# 그 위에 볼륨 그룹 생성
sudo vgcreate <VG 이름> /dev/sda1

# 볼륨 그룹의 남은 공간 전체를 하나의 논리 볼륨으로 (100%FREE = 전부)
sudo lvcreate -l 100%FREE -n <LV 이름> <VG 이름>

# 결과 확인 — 실제 디바이스 경로는 /dev/<VG 이름>/<LV 이름>
sudo lvs
```

## 권한 (chmod/chown)과 sudo

```bash
# 소유자:그룹 변경
sudo chown mysql:mysql /data/mysql

# 권한 변경 — 숫자 3자리는 소유자/그룹/전체 각각의 읽기(4)+쓰기(2)+실행(1) 합
sudo chmod 0600 /etc/homelab-secrets/mysql_repl_password   # 소유자만 읽기/쓰기
sudo chmod 0700 /etc/homelab-secrets                        # 소유자만 진입 가능한 디렉터리
sudo chmod 0440 /etc/sudoers.d/90-chan-nopasswd              # 소유자+그룹 읽기 전용 (sudoers 표준 권한)

# sudo 없이 비밀번호 없이 실행 가능한지 확인 (스크립트에서 원격 자동화 전제조건 체크용)
sudo -n true && echo "NOPASSWD sudo OK"
```
`/etc/sudoers.d/`는 `visudo -f <파일>`로만 편집해야 한다 — 문법 오류가 있는 파일이 그대로 저장되면 이후 어떤 sudo 명령도 실패하는 자물쇠 상태가 될 수 있는데, `visudo`는 저장 전에 문법을 검사해서 이를 막아준다.

## 패키지 관리 (apt)

```bash
# 패키지 목록(저장소가 뭘 갖고 있는지) 최신화 — 설치/업그레이드 전 항상 먼저
sudo apt-get update -y

# 설치 / 제거(설정 파일은 남김) / 완전 제거(설정 파일까지)
sudo apt-get install -y <패키지>
sudo apt-get remove -y <패키지>
sudo apt-get purge -y <패키지>

# 전체 업그레이드 (dist-upgrade는 커널 교체처럼 의존성이 크게 바뀌는 것까지 포함)
sudo apt-get upgrade -y
sudo apt-get dist-upgrade -y

# 특정 패키지를 지금 버전에 고정 — 자동 업그레이드로 버전이 바뀌면 안 되는 것(kubelet 등)에 사용
sudo apt-mark hold <패키지>
sudo apt-mark unhold <패키지>

# 더 이상 필요 없는 의존 패키지 정리
sudo apt-get autoremove -y
```

## SSH

```bash
# 키 페어 생성 (비밀번호 없이 서버 간 자동화하려면 필수)
ssh-keygen -t ed25519

# 공개키를 원격 서버의 authorized_keys에 등록 (비밀번호 인증이 아직 될 때 1회 실행)
ssh-copy-id chan@10.5.5.8

# 원격에서 명령 하나만 실행하고 바로 나오기 (스크립트에서 자주 씀)
ssh 10.5.5.8 "sudo systemctl status keepalived"

# 여러 줄 명령을 한 번에 보낼 때
ssh 10.5.5.8 <<'EOF'
sudo mkdir -p /etc/homelab-secrets
sudo chmod 700 /etc/homelab-secrets
EOF
```
"Host key verification failed"는 접속하려는 서버의 SSH 지문이 로컬 `~/.ssh/known_hosts`에 없거나 바뀌었다는 뜻이다 — 재설치된 서버거나, 중간자 공격 가능성도 이론상 있으니 지문이 바뀐 이유를 모른 채 무조건 지우고 재등록하지 않는다.

## 네트워크 확인

```bash
# 이 노드의 IP/인터페이스 목록 (VIP가 실제로 붙어있는지 확인할 때도 이걸로)
ip -4 addr show

# 특정 IP가 어느 인터페이스에 있는지 빠르게 grep
ip -4 addr show | grep 10.5.5.3

# 라우팅 테이블 (기본 게이트웨이 확인)
ip route

# 특정 IP의 MAC 주소 — VIP가 어느 물리 노드에 있는지 ARP로 교차 확인할 때
arp -a | grep 10.5.5.50

# 포트가 응답하는지 (curl로 HTTP까지 확인하거나, nc로 TCP 연결만 확인)
curl -sk --max-time 2 -o /dev/null -w '%{http_code}\n' https://127.0.0.1:6443/livez
nc -zv 10.5.5.4 7480

# DNS 조회 (내부 도메인이 실제로 풀리는지)
getent hosts ceph.home
dig @10.5.5.2 k8s.home +short
```

## 프로세스/자원 확인

```bash
# 실행 중인 프로세스 (풀네임으로 찾기)
ps aux | grep mysqld

# 실시간 CPU/메모리 사용량 (q로 종료)
htop   # 또는 top

# 디스크 여유 공간 / 디렉터리별 용량
df -h
du -sh /data/*
```

## 파일 복사/동기화

```bash
# 로컬↔원격 파일 복사
scp local-file.txt chan@10.5.5.8:/home/chan/

# 디렉터리 동기화 — 권한/소유자/타임스탬프까지 그대로 유지 (-a), 데이터 이전 시 표준
sudo rsync -a /var/lib/mysql.bak/ /data/mysql/

# 스트림으로 디렉터리 전체를 파이프에 태워 옮기기 (예: 로컬 파일시스템 → k8s 파드 안)
tar -C /home/mysql -cf - . | kubectl exec -i <pod> -- tar -C /var/lib/mysql -xf -
```

## crontab — 정기 작업

```bash
# 현재 계정의 크론잡 편집
crontab -e

# 문법: 분 시 일 월 요일 명령 — 매일 새벽 3시(KST) 예시
# 0 3 * * * ~/k8s-cluster/09-etcd-backup.sh >> ~/k8s-cluster/etcd-backup.log 2>&1

# 등록된 크론잡 확인
crontab -l
```

## 자주 헷갈리는 개념

- **`systemctl restart` vs `reload`**: restart는 프로세스를 완전히 죽였다 다시 띄운다(짧은 다운타임 있음). reload는 살아있는 프로세스에 "설정 다시 읽어라" 시그널만 보낸다(무중단이지만, 모든 서비스가 지원하는 건 아니다 — UFW는 `reload`가 사실상 표준).
- **`/etc/fstab`에 UUID를 쓰는 이유**: `/dev/sda1` 같은 디바이스 이름은 디스크를 추가/제거하면 순서가 바뀔 수 있다. UUID는 파티션을 포맷할 때 한 번 정해지면 안 바뀌는 고유값이라, 재부팅 후에도 항상 같은 파티션을 정확히 가리킨다.
- **`kubectl`/`cephadm`처럼 sudo 없이 쓰는 도구와 `systemctl`/`ufw`처럼 항상 sudo가 필요한 도구가 섞여 있는 이유**: kubectl은 `~/.kube/config`(사용자 홈 디렉터리의 개인 설정 파일)의 인증서로 인증하므로 그 파일에 대한 읽기 권한만 있으면 되고, systemctl/ufw는 시스템 전역 상태를 바꾸는 것이라 항상 root 권한(sudo)이 필요하다.
- **`10.5.5.0/24`라는 표기**: `/24`는 CIDR 표기로 앞 24비트(즉 `10.5.5.`까지)가 네트워크를 식별하고 나머지 8비트(`.0~.255`)가 그 안의 개별 호스트라는 뜻이다. 이 저장소의 모든 방화벽 규칙이 이 대역(내부 LAN 전체)을 단위로 허용/차단을 결정한다.
