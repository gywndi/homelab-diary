# Day 4 — MySQL 이중화, 하나가 죽어도 안 멈추게

> [Homelab Diary](../README.md) 시리즈

데이터베이스는 잃어버리면 안 되는 자산이라 k8s 안에 넣지 않고 서버에 직접 깔았습니다. chan08을 실제로 쓰기가 일어나는 source로, chan09를 복제만 받는 replica로 두고, 그 사이를 가상 IP(VIP) 하나로 이었습니다. 애플리케이션 입장에선 어느 쪽이 진짜 source인지 신경 쓸 필요 없이 VIP 하나만 보면 됩니다.

복제는 semi-sync로 골랐습니다. 완전 비동기는 source가 죽는 순간 마지막 몇 건이 날아갈 수 있고, 완전 동기(그룹 복제)는 그만큼 운영이 무거워집니다. semi-sync는 "적어도 한 대는 받았다는 응답이 와야 커밋을 끝난 걸로 친다"는 절충안이고, 지금 트래픽 규모엔 이 정도면 충분합니다. 장애 전환도 같은 이유로 가볍게 갔습니다. Orchestrator 같은 자동 승격 도구 대신 keepalived — VIP만 자동으로 살아있는 쪽으로 옮기고, 진짜 쓰기 권한을 넘기는 승격은 사람이 마지막에 판단하는 방식입니다.

작업은 `01-install-mysql.sh`(설치 + datadir을 `/data/mysql`로 이전) → `02-tune.sh`(buffer pool, server-id, GTID) → `03-generate-secrets.sh`(복제 비밀번호·VRRP 키 생성, 로컬에서 실행) → `04-source-setup.sh`(chan08, 복제 계정 생성 + semi-sync source 플러그인) → `05-replica-setup.sh`(chan09, `CHANGE REPLICATION SOURCE TO` + 복제 시작) → `06-keepalived.sh`(VIP 페일오버) 순으로 흘러갑니다.

`01-install-mysql.sh`에서 한 번 걸려 넘어졌습니다. datadir을 옮기자마자 mysqld가 몇 초 간격으로 재시작을 반복했고, 로그에는 "data dir not found"만 찍혔습니다. 알고 보니 datadir 줄을 sed로 바꾸는 부분이 조용히 실패하고 있었습니다. 우분투 기본 설정 파일엔 이 줄이 이미 `#`으로 주석 처리돼 있어서, "값을 치환하는" sed 패턴이 애초에 매치를 못 한 겁니다. 에러도 없이 그냥 넘어가버리니 한참 헤맸습니다. 지금은 sed 대신 `/etc/mysql/mysql.conf.d/zz-datadir.cnf`라는 새 파일에 datadir을 명시적으로 씁니다. MySQL이 conf.d 안의 파일을 이름 순으로 읽고 나중 값이 이기기 때문에, `zz` 접두어를 붙여 확실히 마지막에 읽히게 만들었습니다.

설정만 해두고 끝내지 않고 실제로 장애를 재현했습니다. chan08 mysql을 강제로 멈추자 약 6초 만에 VIP가 chan09로 넘어갔고, 다시 켜니 우선순위(150 > 100)대로 chan08이 도로 가져갔습니다. 복제 재연결은 기본 60초 간격이라, 곧바로 이어붙고 싶으면 레플리카에서 `STOP REPLICA IO_THREAD; START REPLICA IO_THREAD;`를 한 번 쳐줘야 합니다. 이 구성이 자동으로 하는 건 딱 VIP 이동까지고, chan08이 완전히 죽는 진짜 재해 상황에서 chan09를 새 source로 승격하는 건 여전히 사람 몫입니다. 트래픽이 작고 사람이 바로 붙을 수 있는 지금 규모엔 이 균형이 맞습니다.

페일오버 검증 로그와 각 스크립트 상세는 [`scripts/mysql-ha/README.md`](../scripts/mysql-ha/README.md)에 있습니다.

---
◀ [Day 3 — Kubernetes](day3-kubernetes.md) · [시리즈 목차](../README.md) · [Day 5 — KVM](day5-kvm.md) ▶
