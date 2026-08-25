# Homelab Diary

아무것도 깔려 있지 않은 우분투 서버 두 대를, AI와 대화하면서 하나씩 실제로 동작하는 클러스터로 만들어가는 기록입니다. 1화(Stage 1)에서는 Kubernetes, MySQL 이중화, KVM 가상화까지 — 앞으로 뭘 올리든 버틸 수 있는 기반을 다졌습니다. 왜 이런 선택을 했는지, 어디서 막혔는지, 실제로 무슨 명령어를 쳤는지까지 가감 없이 남깁니다.

대상 서버: chan08(10.5.5.8) · chan09(10.5.5.9) · OS: Ubuntu 24.04 LTS

## 시리즈 목차 (1화 — 기반 다지기)

| Day | 내용 | 스크립트 |
|---|---|---|
| [Day 1](lessons/day1-base-provisioning.md) | 서버가 나를 알아보게 만들기 (SSH, sudo, 패키지, 타임존, 디스크) | [`scripts/provision/`](scripts/provision/) |
| [Day 2](lessons/day2-firewall.md) | 방화벽, 미리 막고 필요한 것만 열기 | [`scripts/provision/05-firewall-stage1.sh`](scripts/provision/05-firewall-stage1.sh) |
| [Day 3](lessons/day3-kubernetes.md) | Kubernetes 클러스터 구축 (+ CoreDNS 장애 해결기) | [`scripts/k8s-cluster/`](scripts/k8s-cluster/) |
| [Day 4](lessons/day4-mysql-ha.md) | MySQL active/standby 이중화 (+ datadir 이전 장애 해결기) | [`scripts/mysql-ha/`](scripts/mysql-ha/) |
| [Day 5](lessons/day5-kvm.md) | KVM 하이퍼바이저 인프라 준비 | [`scripts/kvm/`](scripts/kvm/) |

