# 진행 상태

세부 아키텍처와 배경은 `specs/overview.md` 참고. 하드웨어 확장 순서대로 Stage를 나눈다 — **지금은 Stage 1(chan08, chan09 2대)만 진행.**

## Stage 1 — chan08 + chan09 2대 구성

### Phase 0 — 서버 기본 프로비저닝 ✅ (2026-08-24 완료)
- [x] SSH 키 인증 확인 (chan08, chan09)
- [x] chan 계정 sudo NOPASSWD (`/etc/sudoers.d/90-chan-nopasswd`)
- [x] 패키지 업데이트, 타임존(Asia/Seoul), UFW 방화벽(10.5.5.0/24), `/data` XFS 마운트
- [x] 재부팅 후 전체 검증 완료
- [x] 스크립트/문서: `provision/` (00~04 스크립트 + README.md)

### Phase 1 — 방화벽 재정리 ✅ (2026-08-24 완료)
- [x] MySQL(3306), keepalived(vrrp) 포트 반영
- [x] 미사용 Calico 포트(179/tcp, 4789/udp) 제거 — `provision/05-firewall-stage1.sh`

### Phase 2 — Kubernetes 클러스터 구축 (2노드) ✅ (2026-08-24 완료)
- [x] CNI 결정: Flannel
- [x] containerd(SystemdCgroup) + kubeadm/kubelet/kubectl(v1.36.4) 설치
- [x] chan08 컨트롤플레인 init, chan09 워커 join, 둘 다 Ready
- [x] 클러스터 내부 DNS 동작 확인 (coredns FQDN 조회 성공)
- [x] 이슈: UFW `DEFAULT_FORWARD_POLICY=DROP`이 pod→서비스 포워딩을 막아 coredns가 API에 연결 못하던 문제 발견 → `k8s-cluster/06-fix-ufw-forward.sh`로 ACCEPT 변경(양쪽 노드), 인바운드 규칙은 그대로 10.5.5.0/24 제한 유지
- 스크립트: `k8s-cluster/` (01~06)

### Phase 3 — MySQL active/standby ✅ (2026-08-24 완료)
- [x] MySQL 8.0.46 호스트 설치, `/data/mysql` datadir, buffer pool 2G 튜닝
- [x] 복제 구성 (semi-sync, chan08=source/chan09=replica)
- [x] keepalived VIP(10.5.5.210) 페일오버 구성, 양방향 전환 테스트 완료
- [x] 실데이터 복제 검증 완료 (장애 전/후 모두)
- [ ] 백업은 우선 로컬 `/data`에 보관 (NAS 연동은 Stage 5) — 백업 스케줄링 자체는 아직 미설정
- 스크립트: `mysql-ha/` (01~06), 알려진 이슈/운영 방식은 `mysql-ha/README.md` 참고

### Phase 4 — KVM 기반 VM ✅ (2026-08-24 완료)
- [x] libvirt/qemu-kvm 설치, `chan` 계정 libvirt/kvm 그룹 추가
- [x] `/data/vms`를 `data-pool` storage pool로 등록 (양쪽 노드)
- 실제 VM은 미생성 (Stage 1 범위 밖, 워크로드 확정 시 진행)
- 스크립트: `kvm/01-setup-libvirt.sh`, `kvm/README.md`

## Stage 1 완료 (2026-08-24)
방화벽 → k8s 2노드(Flannel) → MySQL active/standby(semi-sync + keepalived VIP) → KVM 인프라까지 전부 완료 및 검증. 다음은 Stage 2(8G 노드 추가)부터.

## Stage 2 — 8G 메모리 소형 노드 추가
- [ ] k8s 워커로만 join (MySQL/VM 배치 안 함)

## Stage 3 — GPU 머신 추가 (16G VRAM)
- [ ] 독립 LLM 추론 서버로 셋업 (k8s 미편입, 결정됨)
- [ ] 서빙 스택/네트워크 노출 방식 결정

## Stage 4 — Mac Studio 추가 (96G 통합메모리)
- [ ] 독립 LLM 추론 서버로 셋업 (k8s 미편입)
- [ ] 서빙 스택/네트워크 노출 방식 결정

## Stage 5 — NAS 연동
- [ ] NAS 프로토콜/용량 확인
- [ ] k8s NFS StorageClass 구성
- [ ] MySQL/VM 백업 타깃을 NAS로 전환

## 미결정 사항 (Stage 1부터 순서대로)
- CNI: Flannel vs Calico
- MySQL 장애 전환: keepalived VIP(권장) vs 자동화 도구
- VM 대상 워크로드 목록
- (Stage 3, 4) LLM 서빙 활용 방식
- (Stage 5) NAS 프로토콜/용량/접근 정보
