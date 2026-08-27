# MySQL active/standby (Stage 1)

chan08(source) ↔ chan09(replica), semi-sync 복제, keepalived VIP `10.5.5.4`로 페일오버.

MySQL 8.0.46, datadir `/data/mysql`, `innodb_buffer_pool_size=2G`. k8s 밖에 호스트 네이티브로 설치 — 클러스터가 흔들려도 데이터는 별도로 보호하기 위함.

## 설계 결정

- **복제: semi-sync.** 완전 비동기는 source 장애 시 마지막 트랜잭션 유실 가능, 완전 동기(그룹 복제)는 이 트래픽 규모엔 과한 운영 비용. semi-sync는 최소 1개 복제본의 수신 확인 후 커밋 완료 처리.
- **장애 전환: keepalived VIP만 자동, source 승격은 수동.** Orchestrator류 자동 승격 도구 대신 채택 — VIP 이동은 자동화하되 실제 쓰기 권한 이전은 사람이 판단(아래 "애플리케이션 연결" 참고).

## 스크립트 목록 (이름 순)

### MySQL 설치 + datadir 이전
- 설명: MySQL을 설치하고 datadir을 이전한다 (양쪽).
- 스크립트: [`01-install-mysql.sh`](../scripts/03-mysql-ha/01-install-mysql.sh)
```bash
# MySQL 8.0 서버 설치 (설치와 동시에 기본 경로로 자동 기동됨)
sudo apt-get install -y mysql-server

# 데이터 폴더를 옮기기 전에 서비스 정지
sudo systemctl stop mysql

# 기존 데이터 폴더를 삭제하지 않고 이름만 바꿔 백업
sudo mv /var/lib/mysql /var/lib/mysql.bak.<타임스탬프>

# 실제 데이터를 새 위치로 복사 (권한·소유자·타임스탬프 그대로 유지)
sudo rsync -a /var/lib/mysql.bak.<타임스탬프>/ /data/mysql/

# 복사 과정에서 바뀌었을 수 있는 소유자를 mysql 계정으로 되돌림
sudo chown -R mysql:mysql /data/mysql
```
AppArmor(리눅스 커널의 강제 접근 제어 — mysqld가 접근 가능한 경로를 화이트리스트로 제한한다) 로컬 오버라이드 파일에 두 줄 추가 후 재시작 (새 데이터 경로에 대한 접근 허용):
```bash
/data/mysql/ r,
/data/mysql/** rwk,
```
```bash
# 방금 추가한 AppArmor 규칙 반영
sudo systemctl restart apparmor
```
`/etc/mysql/mysql.conf.d/zz-datadir.cnf`에 아래 내용 작성(Ubuntu 기본 `mysqld.cnf`의 datadir 줄은 주석 처리돼 있어 sed로 못 건드림):
```bash
[mysqld]
datadir = /data/mysql
```
```bash
# 새 datadir 설정으로 MySQL 기동
sudo systemctl start mysql
```

### 튜닝 설정
- 설명: buffer pool·server-id·binlog/GTID를 설정한다 (양쪽).
- 스크립트: [`02-tune.sh`](../scripts/03-mysql-ha/02-tune.sh)
`/etc/mysql/mysql.conf.d/zz-stage1-tuning.cnf`에 아래 내용 작성 (server-id는 chan08=1, chan09=101):
```bash
[mysqld]
innodb_buffer_pool_size = 2G
server-id = 1
log_bin = /data/mysql/mysql-bin
gtid_mode = ON
enforce_gtid_consistency = ON
binlog_format = ROW
bind-address = 0.0.0.0
```
```bash
# 튜닝 값 반영을 위해 재시작
sudo systemctl restart mysql
```

### 비밀번호/인증키 생성
- 설명: 복제 비밀번호 / VRRP 인증키를 생성한다 (로컬 관리 머신에서 실행).
- 스크립트: [`03-generate-secrets.sh`](../scripts/03-mysql-ha/03-generate-secrets.sh)
```bash
# 복제 계정용 비밀번호를 예측 불가능한 값으로 생성
openssl rand -base64 24

# VRRP(keepalived가 노드 간 "누가 VIP를 들 차례인지" 합의할 때 쓰는 프로토콜) 인증키 생성
# (keepalived auth_pass는 8자 제한)
openssl rand -hex 4
```
생성한 두 값을 양쪽 서버의 전용 시크릿 디렉터리에 배포 (root의 홈 디렉터리와 분리, `/etc/homelab-secrets` 0700 root:root):
```bash
# 전용 디렉터리 생성 (양쪽)
ssh 10.5.5.8 "sudo mkdir -p /etc/homelab-secrets && sudo chmod 700 /etc/homelab-secrets"
ssh 10.5.5.9 "sudo mkdir -p /etc/homelab-secrets && sudo chmod 700 /etc/homelab-secrets"

# chan08에 복제 비밀번호 저장
ssh 10.5.5.8 "echo '<복제 비밀번호>' | sudo tee /etc/homelab-secrets/mysql_repl_password"

# chan08에 VRRP 인증키 저장
ssh 10.5.5.8 "echo '<VRRP 인증키>' | sudo tee /etc/homelab-secrets/keepalived_vrrp_pass"

# chan09에 동일한 복제 비밀번호 저장
ssh 10.5.5.9 "echo '<복제 비밀번호>' | sudo tee /etc/homelab-secrets/mysql_repl_password"

# chan09에 동일한 VRRP 인증키 저장
ssh 10.5.5.9 "echo '<VRRP 인증키>' | sudo tee /etc/homelab-secrets/keepalived_vrrp_pass"

# 양쪽 다 소유자/권한 정리
ssh 10.5.5.8 "sudo chown root:root /etc/homelab-secrets/*; sudo chmod 600 /etc/homelab-secrets/*"
ssh 10.5.5.9 "sudo chown root:root /etc/homelab-secrets/*; sudo chmod 600 /etc/homelab-secrets/*"
```

### 복제 소스 설정
- 설명: 복제 소스를 설정한다 (chan08 전용).
- 스크립트: [`04-source-setup.sh`](../scripts/03-mysql-ha/04-source-setup.sh)
```bash
# 내부망에서만 접속 가능한 복제 전용 계정 생성 + 복제 권한 부여
mysql <<SQL
CREATE USER 'replicator'@'10.5.5.%' IDENTIFIED BY '<복제 비밀번호>';
GRANT REPLICATION SLAVE ON *.* TO 'replicator'@'10.5.5.%';
SQL

# semi-sync 복제 기능(source 쪽)을 플러그인으로 설치
mysql -e "INSTALL PLUGIN rpl_semi_sync_source SONAME 'semisync_source.so';"

# semi-sync 즉시 활성화
mysql -e "SET GLOBAL rpl_semi_sync_source_enabled = 1;"

# 재시작 후에도 유지되도록 영구 설정
mysql -e "SET PERSIST rpl_semi_sync_source_enabled = 1;"
```

### 복제 레플리카 설정
- 설명: 복제 레플리카를 설정한다 (chan09 전용).
- 스크립트: [`05-replica-setup.sh`](../scripts/03-mysql-ha/05-replica-setup.sh)
```bash
# semi-sync 복제 기능(replica 쪽) 설치
mysql -e "INSTALL PLUGIN rpl_semi_sync_replica SONAME 'semisync_replica.so';"

# semi-sync 즉시 활성화 + 재시작 후에도 유지
mysql -e "SET GLOBAL rpl_semi_sync_replica_enabled = 1;"
mysql -e "SET PERSIST rpl_semi_sync_replica_enabled = 1;"

# chan08을 복제 소스로 지정하고 복제 시작 (GTID 기반이라 위치를 직접 지정할 필요 없음)
mysql <<SQL
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='10.5.5.8',
  SOURCE_USER='replicator',
  SOURCE_PASSWORD='<복제 비밀번호>',
  SOURCE_AUTO_POSITION=1;
START REPLICA;
SQL
```

### VIP 페일오버 구성
- 설명: VIP 페일오버를 구성한다 (양쪽).
- 스크립트: [`06-keepalived.sh`](../scripts/03-mysql-ha/06-keepalived.sh)
```bash
# VIP 페일오버를 담당하는 프로그램 설치
sudo apt-get install -y keepalived
```
`/etc/keepalived/keepalived.conf`의 `vrrp_instance` 핵심 값 (chan08 / chan09):
```bash
# chan08: state MASTER, priority 150 — 정상 시 항상 VIP를 가져감
# chan09: state BACKUP, priority 100
# 공통: virtual_ipaddress 10.5.5.4/24
```
헬스체크 스크립트(`/usr/local/bin/chk_mysql.sh`)는 mysqld 생존 확인 앞에 **수동 게이트 파일** 체크를 추가로 거친다:
```bash
# /etc/keepalived/allow_master가 없으면 mysqld가 멀쩡해도 실패 처리
[[ -f /etc/keepalived/allow_master ]] && mysqladmin ping -h 127.0.0.1 --silent
```
```bash
# 평소엔 이 파일이 있어야 정상 동작 (스크립트가 기본 생성)
sudo touch /etc/keepalived/allow_master
```
```bash
# 설정 반영을 위해 재시작
sudo systemctl restart keepalived
```

**게이트 파일의 용도**: 장애로 반대쪽이 소스로 수동 승격된 뒤, 원래 노드가 재부팅 등으로 되살아나도 keepalived 우선순위(chan08=150 > chan09=100) 때문에 **자동으로 VIP를 다시 뺏어가는 것(페일백)을 막기 위함**이다. `mysqladmin ping`은 "mysqld가 응답하는지"만 볼 뿐 "데이터가 최신인지"는 전혀 확인 안 하므로, 그대로 두면 오래된 데이터를 가진 노드로 쓰기 트래픽이 몰릴 위험이 있다. 실제 장애 시 대응 순서:
1. chan09를 소스로 수동 승격 (기존 "애플리케이션 연결" 절차)
2. chan08의 게이트 파일 제거: `sudo rm /etc/keepalived/allow_master` — 이후 chan08의 mysqld가 살아나도 마스터 후보에서 계속 배제됨
3. chan08을 chan09의 새 레플리카로 재동기화
4. 정상 확인 후 게이트 파일 재생성: `sudo touch /etc/keepalived/allow_master` — 그제서야 chan08이 다시 후보로 복귀 (우선순위상 즉시 VIP를 다시 가져감)

## 알려진 이슈: [`01-install-mysql.sh`](../scripts/03-mysql-ha/01-install-mysql.sh) 초기 버전 datadir sed 실패

Ubuntu 기본 `mysqld.cnf`의 `datadir` 줄은 `# datadir = /var/lib/mysql`처럼 **주석 처리**되어 있어, `sed`로 값만 바꾸는 방식은 매치되지 않아 조용히 실패했다. 그 결과 `/var/lib/mysql`을 이미 옮긴 상태에서 mysqld가 기본 경로를 찾지 못해 재시작 루프에 빠졌다.

현재 스크립트는 `sed` 대신 `/etc/mysql/mysql.conf.d/zz-datadir.cnf`라는 새 conf.d 파일에 `datadir = /data/mysql`을 명시적으로 써서 우회한다 (파일명이 알파벳순으로 `mysqld.cnf`보다 뒤라 확실히 우선 적용됨). 복구가 필요했다면 `systemctl reset-failed mysql` 후 재기동.

## 알려진 이슈: `allow_master` 게이트 파일의 운영 리스크

- **양쪽 게이트 파일이 동시에 없어지면 완전 장애.** 둘 다 헬스체크가 실패해서 아무도 VIP를 못 받는 상태가 된다 — 페일백을 막으려던 안전장치가 잘못 다루면 새로운 단일 장애점이 될 수 있다.
- **서버 재설치 시 까먹기 쉽다.** 새로 프로비저닝한 노드는 이 파일이 없는 상태로 시작하므로, [`06-keepalived.sh`](../scripts/03-mysql-ha/06-keepalived.sh)가 기본으로 생성해주지 않으면 "mysqld는 멀쩡한데 왜 마스터가 안 되는지" 한참 헤매게 된다.
- **반영까지 최대 6초 지연된다** (`fall 3 × interval 2초`). 파일을 지워도 즉시가 아니라 최대 6초 후에 실제로 배제되므로, 급한 강제전환 상황에서 성급하게 "안 바뀐다"고 판단하면 안 된다.
- **"진짜 장애냐 순간 블립이냐" 판단은 여전히 사람 몫이다.** 게이트 파일이 이 판단 자체를 대신해주지는 않는다 — chan08이 잠깐 재부팅된 것뿐이고 chan09가 실제로 승격된 적이 없다면, 게이트 파일을 안 건드리고 그냥 두는 게 맞다(정상적인 우선순위 기반 자동 복귀가 오히려 맞는 동작).
- **`vrrp_script`에 `weight`를 설정하지 않았기 때문에, 헬스체크 실패 시 우선순위가 깎이는 게 아니라 그 인스턴스가 선거에서 완전히 배제(FAULT)된다.** 의도한 동작이지만, 나중에 누군가 `weight`를 추가하면 이 배제 동작이 "우선순위 소폭 감소"로 바뀌어서 게이트가 무력화될 수 있다.

## 페일오버 동작 검증 (2026-08-24 완료)

1. chan08 `mysql` 정지 → keepalived 헬스체크(`interval 2, fall 3`, 약 6초)가 실패 감지 → VIP가 chan09로 이동 확인
2. chan08 `mysql` 재기동 → priority(150 > 100)로 preemptive하게 VIP가 chan08로 복귀
3. 복제 IO 스레드는 소스가 끊겼다 살아나면 기본 60초 재시도 간격(`SOURCE_RETRY_COUNT`/`SOURCE_CONNECT_RETRY` 기본값)으로 대기함 — 계획된 페일백 직후 바로 동기화하고 싶으면 레플리카에서 수동으로:
   ```sql
   STOP REPLICA IO_THREAD; START REPLICA IO_THREAD;
   ```
4. 재연결 후 실제 데이터 복제(테스트 DB 생성 → 반대편에서 조회) 확인 완료

## 애플리케이션 연결

MySQL 클라이언트는 **VIP `10.5.5.4:3306`**으로 접속. 어느 쪽이 source인지 신경 쓸 필요 없이 keepalived가 항상 현재 source(우선순위가 높은 쪽, 정상 시 chan08)로 트래픽을 보낸다.

주의: 이 구성은 자동 페일오버(VIP 이동)만 하고, **레플리카를 자동으로 새 source로 승격하지 않는다** (semi-sync replica는 여전히 chan08을 SOURCE_HOST로 바라봄). chan08 자체가 완전히 죽는 실제 장애 시엔 chan09를 수동으로 승격(`RESET REPLICA ALL`, 쓰기 허용 등)해야 한다. Stage 1 범위에서는 "VIP 자동 전환 + 승격은 수동" 정도로 충분하다고 판단했다 (트래픽이 작고, 운영자가 상주하는 환경).

## 검증 명령

```bash
# 복제 상태 확인 (chan09에서 실행)
sudo mysql -e "SHOW REPLICA STATUS\G"

# semi-sync 상태
sudo mysql -e "SHOW STATUS LIKE 'Rpl_semi_sync%';"

# VIP 위치
ip -4 addr show enp1s0 | grep 10.5.5.4
```
