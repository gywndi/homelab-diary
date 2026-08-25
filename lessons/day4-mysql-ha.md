# Day 4 — MySQL 이중화, 하나가 죽어도 안 멈추게

> [AI로 함께 만든 클러스터](../README.md) 시리즈

데이터베이스는 잃어버리면 안 되는 자산이라, k8s 안에 넣지 않고 서버에 직접 설치했습니다. chan08을 실제로 쓰기가 일어나는 source로, chan09를 계속 복제만 받는 replica로 두고, 그 둘 사이를 가상 IP(VIP)로 연결해서 애플리케이션은 어느 쪽이 진짜 source인지 신경 쓸 필요 없이 항상 같은 주소로만 접속하면 되도록 만들었습니다.

복제 방식은 semi-sync를 선택했습니다. 완전 비동기 복제는 source가 갑자기 죽는 순간 아직 복제되지 않은 마지막 몇 건의 데이터가 사라질 위험이 있고, 반대로 완전 동기(그룹 복제 같은) 방식은 그만큼 설정과 운영이 훨씬 복잡해집니다. semi-sync는 "적어도 한 대는 확실히 데이터를 받았다는 응답을 받은 뒤에야 커밋을 완료 처리"하는 방식이라, 복잡도 대비 안정성이 좋은 절충안이었습니다. 장애 전환 방식도 비슷한 고민을 거쳤습니다. Orchestrator 같은 자동 승격 도구는 강력하지만 배우고 운영할 게 많습니다. 트래픽이 크지 않고 사람이 바로 대응할 수 있는 규모라, "장애가 감지되면 가상 IP만 자동으로 살아있는 쪽으로 옮겨주고, 진짜 쓰기 권한을 넘기는 승격은 사람이 최종 판단"하는 가벼운 방식(keepalived)을 골랐습니다.

## 겪었던 문제 — datadir을 옮겼는데 MySQL이 계속 재시작을 반복했다

데이터 폴더를 `/var/lib/mysql`에서 `/data/mysql`로 옮기는 스크립트를 돌렸는데, MySQL이 시작하자마자 몇 초 간격으로 계속 죽었다 켜지길 반복했습니다. 로그에는 "data dir not found"라는 오류만 찍혀 있었습니다.

원인을 찾아보니, 설정 파일에서 datadir이 적힌 줄을 자동으로 바꾸려던 명령이 조용히 실패하고 있었습니다. 우분투 기본 설정 파일에는 이 줄이 `#`으로 이미 주석 처리된 채로 들어 있었는데, "값을 바꾸는" 방식의 명령은 이 줄을 찾지 못하면 에러 없이 그냥 아무 일도 하지 않고 넘어가 버립니다. 그 결과 MySQL은 이미 옮겨서 사라진 원래 경로(`/var/lib/mysql`)를 계속 찾다가 실패하고 있었던 겁니다.

기존 줄을 억지로 고치려 하지 않고, 새 설정 파일을 하나 더 만들어서 거기에 새 경로를 명확하게 적는 방식으로 우회했습니다. MySQL은 설정 파일들을 이름 순서대로 읽고 나중에 읽은 파일이 앞선 값을 덮어쓰기 때문에, 이 방법을 쓰면 기존 줄이 주석인지 아닌지 신경 쓸 필요 없이 항상 확실하게 적용됩니다.

## 장애 상황을 직접 재현해서 검증

설정만 해두고 끝내지 않고, 실제로 chan08의 MySQL을 강제로 멈춰서 가상 IP가 chan09로 정말 넘어가는지, 다시 살렸을 때 원래대로 돌아오는지까지 검증했습니다. 정지시키고 약 6초 만에 VIP가 chan09로 이동했고, 다시 켜자 우선순위 설정(chan08 150 > chan09 100)에 따라 VIP가 chan08로 돌아왔습니다. 다만 복제 연결은 기본적으로 60초 간격으로 재시도하도록 되어 있어서, 곧바로 이어지길 원한다면 복제 IO 스레드를 수동으로 한 번 재시작해줘야 했습니다.

이 구성이 자동으로 해주는 건 딱 거기까지입니다 — 가상 IP를 살아있는 서버로 옮겨주는 것. chan08이 완전히 죽어버리는 진짜 재해 상황에서는, chan09를 실제로 쓰기가 가능한 새로운 source로 승격하는 건 여전히 사람이 판단해서 해야 합니다. 트래픽이 작고 사람이 바로 대응 가능한 지금 규모에서는 이 정도가 딱 맞는 균형점이라고 봤습니다.

## 이 단계에서 쓴 명령어

- **`sudo apt-get install mysql-server`** — MySQL 8.0 서버를 설치합니다. 설치와 동시에 기본 경로(`/var/lib/mysql`)로 서비스가 자동으로 시작됩니다.
- **`sudo systemctl stop mysql`** — 데이터 폴더를 옮기기 전에 서비스를 먼저 멈춥니다. 서비스가 파일을 쓰고 있는 도중에 폴더를 옮기면 데이터가 깨질 수 있습니다.
- **`sudo mv /var/lib/mysql /var/lib/mysql.bak.날짜` 후 `sudo rsync -a 백업위치/ /data/mysql/`** — 기존 데이터를 삭제하지 않고 이름만 바꿔 백업으로 남긴 뒤, 실제 데이터를 새 위치로 복사합니다. `rsync -a`는 권한, 소유자, 타임스탬프까지 원본 그대로 유지하며 복사해주는 옵션입니다.
- **`sudo chown -R mysql:mysql /data/mysql`** — 새로 옮긴 폴더의 소유자를 mysql 계정으로 되돌립니다. 복사 과정에서 소유자가 바뀌었을 수 있는데, MySQL은 자기 소유가 아닌 데이터 폴더는 시작을 거부합니다.
- **`/etc/apparmor.d/local/usr.sbin.mysqld`에 `/data/mysql/** rwk` 추가 후 `sudo systemctl restart apparmor`** — 우분투는 AppArmor라는 보안 모듈로 MySQL이 접근할 수 있는 경로를 원래부터 제한해둡니다. 데이터 폴더를 옮겼다면 이 허용 목록에도 새 경로를 추가해줘야, MySQL이 "권한이 없다"며 새 경로에 쓰기를 거부하는 사고를 막을 수 있습니다.
- **`/etc/mysql/mysql.conf.d/zz-datadir.cnf`에 `datadir = /data/mysql` 작성** — 앞서 설명한 sed 실패 문제의 실제 해결책입니다. 파일명 앞에 `zz`를 붙인 이유는, MySQL이 conf.d 폴더 안의 설정 파일들을 이름 순서대로 읽어서 나중에 읽은 값이 우선 적용되기 때문에, 알파벳상 확실히 마지막에 읽히도록 만든 겁니다.
- **`/etc/mysql/mysql.conf.d/zz-stage1-tuning.cnf`에 `innodb_buffer_pool_size=2G`, `server-id`, `log_bin`, `gtid_mode=ON`, `binlog_format=ROW` 작성** — 이 서버 규모에 맞춘 핵심 튜닝 값들입니다. `innodb_buffer_pool_size`는 자주 쓰는 데이터를 메모리에 얼마나 캐싱해둘지 정하는 값으로, 내부 트래픽 규모에서는 2GB로 충분하다고 판단했습니다. `server-id`는 복제에 참여하는 서버마다 반드시 달라야 하는 고유 번호이고, `gtid_mode`와 `log_bin`은 복제가 정확히 어디까지 진행됐는지 추적 가능하게 해주는 설정입니다.
- **`openssl rand -base64 24`** — 복제 계정에 쓸 임의의 비밀번호를 생성합니다. 사람이 기억하기 쉬운 비밀번호 대신, 예측 불가능한 값을 자동으로 만들어 각 서버의 root 권한 파일에만 저장했습니다.
- **`CREATE USER 'replicator'@'10.5.5.%' IDENTIFIED BY '...'; GRANT REPLICATION SLAVE ON *.* TO 'replicator'@'10.5.5.%';`** — 복제 전용 계정을 만듭니다. `10.5.5.%`로 접속 가능한 대역을 내부망으로 한정해서, 혹시 비밀번호가 유출되더라도 외부에서는 이 계정을 쓸 수 없게 했습니다.
- **`INSTALL PLUGIN rpl_semi_sync_source SONAME 'semisync_source.so';` (source), `INSTALL PLUGIN rpl_semi_sync_replica SONAME 'semisync_replica.so';` (replica)** — 앞서 설명한 semi-sync 복제 기능 자체를 MySQL에 추가로 설치하는 명령입니다. 기본 MySQL에는 이 기능이 플러그인 형태로 빠져 있어서 따로 설치해야 합니다.
- **`CHANGE REPLICATION SOURCE TO SOURCE_HOST='10.5.5.8', SOURCE_USER='replicator', SOURCE_PASSWORD='...', SOURCE_AUTO_POSITION=1; START REPLICA;`** — chan09에서 실행해서, "나는 이제부터 chan08의 복제본이다"라고 선언하고 복제를 시작하는 명령입니다. `SOURCE_AUTO_POSITION=1`은 어디서부터 복제를 이어받을지를 GTID를 이용해 MySQL이 알아서 계산하게 해주는 옵션으로, 사람이 로그 파일 이름과 위치를 직접 지정하지 않아도 됩니다.
- **`SHOW REPLICA STATUS\G`** — 복제가 정상적으로 진행되고 있는지 확인하는 명령입니다. `Replica_IO_Running`과 `Replica_SQL_Running`이 둘 다 `Yes`인지를 계속 확인하며 작업했습니다.
- **`sudo apt-get install keepalived`** — 가상 IP 페일오버 기능을 담당하는 프로그램을 설치합니다.
- **`/etc/keepalived/keepalived.conf`에 `vrrp_script`(mysqld 상태 확인)와 `vrrp_instance`(가상 IP, 우선순위) 작성** — keepalived의 핵심 설정입니다. `vrrp_script`는 2초마다 로컬 MySQL이 살아있는지 확인하는 헬스체크이고, `vrrp_instance`는 이 서버가 MASTER인지 BACKUP인지, 가상 IP는 무엇인지, 우선순위는 몇인지를 정의합니다. chan08은 우선순위 150, chan09는 100으로 둬서, 정상 상황에서는 항상 chan08이 VIP를 가져가도록 했습니다.
- **`sudo systemctl stop mysql` (테스트용)** — 장애 상황을 실제로 재현하기 위해 chan08의 MySQL을 일부러 멈춰서, keepalived가 정말로 VIP를 옮기는지 눈으로 확인했습니다.
- **`STOP REPLICA IO_THREAD; START REPLICA IO_THREAD;`** — 복제 연결이 끊긴 뒤 기본 재시도 간격(60초)을 기다리지 않고, 즉시 다시 연결을 시도하도록 강제하는 명령입니다.

## 이 레슨에서 쓴 스크립트

[`scripts/mysql-ha/`](../scripts/mysql-ha/) — `01-install-mysql.sh` → `02-tune.sh` → `03-generate-secrets.sh`(로컬에서 실행) → `04-source-setup.sh`(chan08) → `05-replica-setup.sh`(chan09) → `06-keepalived.sh`. 겪었던 문제와 페일오버 검증 로그는 [`scripts/mysql-ha/README.md`](../scripts/mysql-ha/README.md)에 더 자세히 있습니다.

---
◀ [Day 3 — Kubernetes](day3-kubernetes.md) · [시리즈 목차](../README.md) · [Day 5 — KVM](day5-kvm.md) ▶
