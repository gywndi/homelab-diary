# Homelab Diary

우분투 서버(chan08, chan09, llm001)에 Kubernetes 클러스터, Ceph 스토리지, MySQL, StarRocks, KVM 가상화 기반까지 구성한 프로비저닝 스크립트와 구성 문서 모음.

대상 서버: chan08(10.5.5.8) · chan09(10.5.5.9) · llm001(10.5.5.10, GPU) · OS: Ubuntu 24.04 LTS

## 구성 요소 (Stage 1)

1. 서버 초기 프로비저닝
   - SSH, sudo, 패키지, 타임존, 방화벽, 데이터 디스크
   - 문서 [바로가기](lessons/01-provision.md) · 스크립트 [바로가기](scripts/01-provision/)
2. Kubernetes 클러스터
   - 2노드, Flannel CNI, 컨트롤플레인은 처음부터 keepalived VIP를 진입점으로 사용
   - 문서 [바로가기](lessons/02-k8s-cluster.md) · 스크립트 [바로가기](scripts/02-k8s-cluster/)
3. MySQL active/standby
   - semi-sync + keepalived VIP
   - 문서 [바로가기](lessons/03-1-mysql-ha.md) · 스크립트 [바로가기](scripts/03-mysql-ha/)
   - 이후 Ceph RBD 기반 단일 인스턴스로 전환: 문서 [바로가기](lessons/03-2-mysql-ceph-migration.md)
4. Ingress + 인증서 자동화
   - MetalLB + ingress-nginx + cert-manager
   - 문서 [바로가기](lessons/04-1-ingress.md) · 운영 명령 [바로가기](lessons/04-2-ingress-ops.md) · 스크립트 [바로가기](scripts/04-ingress/)
5. LLM GPU 노드 추가 (3노드, 컨트롤플레인 HA)
   - GPU 워커 편입 + etcd 쿼럼 3 구성
   - 문서 [바로가기](lessons/05-llm-gpu-node.md) · 스크립트 [바로가기](scripts/05-llm-gpu-node/)
6. KVM 하이퍼바이저 인프라
   - k8s와 무관한 별도 가상화 기반 (컨테이너화가 어려운 워크로드용)
   - 문서 [바로가기](lessons/06-1-kvm.md) · 스크립트 [바로가기](scripts/06-kvm/)
7. Ceph 스토리지 (RBD/RGW)
   - 3노드 재구성, cephadm으로 베어메탈 배포(k8s와 무관하게 독립 운영)
   - 문서 [바로가기](lessons/07-1-ceph-storage.md) · 벤치마크 [바로가기](lessons/07-2-ceph-storage-bmt.md) · 스크립트 [바로가기](scripts/07-ceph-storage/)
8. StarRocks 분석 엔진 (FE/CN, shared-data)
   - Ceph RGW를 오브젝트 스토리지로 쓰는 shared-data 클러스터 + 비교용 shared-nothing 클러스터
   - 문서 [바로가기](lessons/08-1-starrocks-analytics.md) · 벤치마크 [바로가기](lessons/08-2-starrocks-analytics-bmt.md) · 아카이브 적합성 [바로가기](lessons/08-3-starrocks-archive-fitness.md) · 운영 명령 [바로가기](lessons/08-4-starrocks-ops.md) · 스크립트 [바로가기](scripts/08-starrocks/)
9. 내부 도메인 DNS (CoreDNS)
   - LAN·k8s 파드 양쪽에서 `k8s.home`/`ceph.home` 같은 이름으로 서비스 VIP 접속
   - 문서 [바로가기](lessons/09-internal-dns.md)

## 운영 명령 모음

구축 절차가 아니라 평소 운영 중 상태 확인·트러블슈팅용 명령을 모아둔 문서.

- [k8s 운영](lessons/ops-k8s.md) · [Ceph 운영](lessons/ops-ceph.md) · [StarRocks 운영](lessons/08-4-starrocks-ops.md) · [Ingress 운영](lessons/04-2-ingress-ops.md)
- [리눅스 기본 상식](lessons/ops-linux-basics.md) — 위 운영 문서들에 나오는 명령을 이해하기 위한 systemd/UFW/디스크/LVM/SSH 등 공통 기초

`lessons/`에 목적, 스크립트별 실행 명령, 설계 결정, 알려진 이슈가 정리되어 있다. `scripts/`에는 실행 스크립트 파일만 있다. `concepts/`에는 [Kubernetes 개념 정리](concepts/01-kubernetes.md), [Ceph 개념 정리](concepts/02-ceph.md), [StarRocks 개념 정리](concepts/03-starrocks.md)처럼 배경 개념 설명을 모아둔다 — 번호는 각 개념이 처음 필요해진 순서(k8s → Ceph → StarRocks)대로 매겼다.
