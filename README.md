# Homelab Diary

우분투 서버 두 대(chan08, chan09)에 Kubernetes 클러스터, MySQL active/standby 이중화, KVM 가상화 기반까지 구성한 프로비저닝 스크립트와 구성 문서 모음.

대상 서버: chan08(10.5.5.8) · chan09(10.5.5.9) · OS: Ubuntu 24.04 LTS

## 구성 요소 (Stage 1)

| 순서 | 구성 요소 | 문서 | 스크립트 |
|---|---|---|---|
| 1 | 서버 초기 프로비저닝 (SSH, sudo, 패키지, 타임존, 방화벽, 데이터 디스크) | [바로가기](lessons/01-provision.md) | [바로가기](scripts/01-provision/) |
| 2 | Kubernetes 클러스터 (2노드, Flannel CNI) | [바로가기](lessons/02-k8s-cluster.md) | [바로가기](scripts/02-k8s-cluster/) |
| 3 | MySQL active/standby (semi-sync + keepalived VIP) | [바로가기](lessons/03-mysql-ha.md) | [바로가기](scripts/03-mysql-ha/) |
| 4 | KVM 하이퍼바이저 인프라 | [바로가기](lessons/04-kvm.md) | [바로가기](scripts/04-kvm/) |

`lessons/`에 목적, 스크립트별 실행 명령, 설계 결정, 알려진 이슈가 정리되어 있다. `scripts/`에는 실행 스크립트 파일만 있다.
