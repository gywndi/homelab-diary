# MySQL active/standby (Stage 1)

chan08(source) ↔ chan09(replica), semi-sync 복제, keepalived VIP `10.5.5.210`로 페일오버.
MySQL 8.0.46, datadir `/data/mysql`, `innodb_buffer_pool_size=2G`.

## 스크립트 순서

| 순서 | 파일 | 대상 | 내용 |
|------|------|------|------|
| 1 | `01-install-mysql.sh` | 양쪽 | mysql-server 설치, datadir을 `/data/mysql`로 이전, AppArmor 로컬 오버라이드 |
| 2 | `02-tune.sh <server-id>` | 양쪽 | buffer pool 2G, server-id(chan08=1, chan09=101), binlog/GTID |
| 3 | `03-generate-secrets.sh` | 로컬(관리 머신) | 복제 비밀번호/VRRP 인증키 생성 후 양쪽 `/root/`에 배포 |
| 4 | `04-source-setup.sh` | chan08만 | 복제 계정 생성, semi-sync source 플러그인 활성화 |
| 5 | `05-replica-setup.sh` | chan09만 | semi-sync replica 플러그인, `CHANGE REPLICATION SOURCE TO`, 복제 시작 |
| 6 | `06-keepalived.sh <MASTER\|BACKUP> <priority>` | 양쪽 | keepalived 설치, VIP 페일오버 구성 |

## 알려진 이슈: `01-install-mysql.sh` 초기 버전 datadir sed 실패

Ubuntu 기본 `mysqld.cnf`의 `datadir` 줄은 `# datadir = /var/lib/mysql`처럼 **주석 처리**되어 있어, `sed`로 값만 바꾸는 방식은 매치되지 않아 조용히 실패했다. 그 결과 `/var/lib/mysql`을 이미 옮긴 상태에서 mysqld가 기본 경로를 찾지 못해 재시작 루프에 빠졌다.

현재 스크립트는 `sed` 대신 `/etc/mysql/mysql.conf.d/zz-datadir.cnf`라는 새 conf.d 파일에 `datadir = /data/mysql`을 명시적으로 써서 우회한다 (파일명이 알파벳순으로 `mysqld.cnf`보다 뒤라 확실히 우선 적용됨). 복구가 필요했다면 `systemctl reset-failed mysql` 후 재기동.

## 페일오버 동작 검증 (2026-08-24 완료)

1. chan08 `mysql` 정지 → keepalived 헬스체크(`interval 2, fall 3`, 약 6초)가 실패 감지 → VIP가 chan09로 이동 확인
2. chan08 `mysql` 재기동 → priority(150 > 100)로 preemptive하게 VIP가 chan08로 복귀
3. 복제 IO 스레드는 소스가 끊겼다 살아나면 기본 60초 재시도 간격(`SOURCE_RETRY_COUNT`/`SOURCE_CONNECT_RETRY` 기본값)으로 대기함 — 계획된 페일백 직후 바로 동기화하고 싶으면 레플리카에서 수동으로:
   ```sql
   STOP REPLICA IO_THREAD; START REPLICA IO_THREAD;
   ```
4. 재연결 후 실제 데이터 복제(테스트 DB 생성 → 반대편에서 조회) 확인 완료

## 애플리케이션 연결

MySQL 클라이언트는 **VIP `10.5.5.210:3306`**으로 접속. 어느 쪽이 source인지 신경 쓸 필요 없이 keepalived가 항상 현재 source(우선순위가 높은 쪽, 정상 시 chan08)로 트래픽을 보낸다.

주의: 이 구성은 자동 페일오버(VIP 이동)만 하고, **레플리카를 자동으로 새 source로 승격하지 않는다** (semi-sync replica는 여전히 chan08을 SOURCE_HOST로 바라봄). chan08 자체가 완전히 죽는 실제 장애 시엔 chan09를 수동으로 승격(`RESET REPLICA ALL`, 쓰기 허용 등)해야 한다. Stage 1 범위에서는 "VIP 자동 전환 + 승격은 수동" 정도로 충분하다고 판단했다 (트래픽이 작고, 운영자가 상주하는 환경).

## 검증 명령

```bash
# 복제 상태
sudo mysql -e "SHOW REPLICA STATUS\G"   # chan09에서

# semi-sync 상태
sudo mysql -e "SHOW STATUS LIKE 'Rpl_semi_sync%';"

# VIP 위치
ip -4 addr show enp1s0 | grep 10.5.5.210
```
