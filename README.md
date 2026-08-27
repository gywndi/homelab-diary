# Homelab Diary

우분투 서버 두 대(chan08, chan09)에 Kubernetes 클러스터, MySQL active/standby 이중화, KVM 가상화 기반까지 구성한 프로비저닝 스크립트와 구성 문서 모음.

대상 서버: chan08(10.5.5.8) · chan09(10.5.5.9) · OS: Ubuntu 24.04 LTS

## 구성 요소 (Stage 1)

1. 서버 초기 프로비저닝
   - SSH, sudo, 패키지, 타임존, 방화벽, 데이터 디스크
   - 문서 [바로가기](lessons/01-provision.md) · 스크립트 [바로가기](scripts/01-provision/)
2. Kubernetes 클러스터
   - 2노드, Flannel CNI, 컨트롤플레인은 처음부터 keepalived VIP를 진입점으로 사용
   - 문서 [바로가기](lessons/02-k8s-cluster.md) · 스크립트 [바로가기](scripts/02-k8s-cluster/)
3. MySQL active/standby
   - semi-sync + keepalived VIP
   - 문서 [바로가기](lessons/03-mysql-ha.md) · 스크립트 [바로가기](scripts/03-mysql-ha/)
4. KVM 하이퍼바이저 인프라
   - 문서 [바로가기](lessons/04-kvm.md) · 스크립트 [바로가기](scripts/04-kvm/)
5. Ingress + 인증서 자동화
   - MetalLB + ingress-nginx + cert-manager
   - 문서 [바로가기](lessons/05-1-ingress.md) · 운영 명령 [바로가기](lessons/05-2-ingress-ops.md) · 스크립트 [바로가기](scripts/05-ingress/)
6. LLM GPU 노드 추가 (3노드, 컨트롤플레인 HA)
   - GPU 워커 편입 + etcd 쿼럼 3 구성
   - 문서 [바로가기](lessons/06-llm-gpu-node.md) · 스크립트 [바로가기](scripts/06-llm-gpu-node/)

`lessons/`에 목적, 스크립트별 실행 명령, 설계 결정, 알려진 이슈가 정리되어 있다. `scripts/`에는 실행 스크립트 파일만 있다. `concepts/`에는 [Kubernetes 개념 정리](concepts/kubernetes.md)처럼 배경 개념 설명을 모아둔다. `work/`에는 검증 중인 진행 작업 초안이 있다 — [Ceph 스토리지 레이어 도입](work/ceph-storage-layer.md), [StarRocks shared-data 배포](work/starrocks-shared-data.md).
