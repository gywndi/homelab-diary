# 인프라 개요

## 목표

내부 트래픽용 소규모 환경 구축. 네 가지 축으로 구성된다.

1. **Kubernetes 클러스터** — 컨테이너화 가능한 일반 워크로드. chan08/chan09(추후 8G 소형 노드 포함) 물리 서버 2~3대에 구축
2. **MySQL active/standby** — k8s 외부, chan08/chan09 호스트에 직접 설치되는 전용 DB (작은 트래픽, buffer pool 2G면 충분)
3. **KVM 기반 VM** — k8s로 옮기기 어려운 워크로드, chan08/chan09에서 남는 자원으로 운영
4. **LLM 서빙** — GPU 머신(16G VRAM)과 Mac Studio(96G 통합메모리) 두 대를 필요에 따라 활용. **k8s에 편입하지 않고 독립 서버로 운영** (사용자 결정)

## 현재 하드웨어

| 항목 | chan08 (10.5.5.8) | chan09 (10.5.5.9) | 비고 |
|------|--------------------|--------------------|------|
| CPU | i5-8500T, 6 core | i5-8500T, 6 core | VT-x(vmx) 지원, kvm 모듈 로드됨 |
| RAM | 32G | 32G | |
| OS 디스크 | ~100G (root LVM) + 135G (/home) | 동일 | nvme |
| 데이터 디스크 | `/data` 932G XFS (`/dev/sda2`) | `/data` 932G XFS (`/dev/sda1`) | [[provision-scripts]] 로 구성 |
| 타임존 | Asia/Seoul | Asia/Seoul | |
| 방화벽 | UFW, 10.5.5.0/24만 인바운드 허용 | 동일 | k8s 포트 기준으로 열어둠 — MySQL/VM 포트 추가 정리 필요 |

추후 계획: 8G 소형 노드, GPU 머신, Mac Studio, NAS 순서로 단계별 추가 예정 (아래 "단계별 진행 순서" 참고). 지금은 chan08/chan09 2대만으로 구성한다.

## LLM 서빙 인프라 (독립 운영)

k8s 클러스터와 별도로 운영. 두 장비 모두 IP/OS/상세 스펙은 아직 미확인 — 접근 정보 확보되면 채워 넣을 것.

| 장비 | 스펙 | 역할 | 비고 |
|------|------|------|------|
| GPU 머신 | GPU VRAM 16G | LLM 추론 서버 (독립) | k8s GPU 워커로 편입하지 않기로 결정 |
| Mac Studio | 통합메모리 96G | LLM 추론 서버 (독립) | |

세부 활용 방식(사용 시점, 모델 배치 기준, 서빙 스택 등)은 나중에 결정.

## 아키텍처 방향

같은 물리 서버 2대에 k8s 노드, MySQL, KVM 하이퍼바이저가 동시에 올라가는 구조. 32G/6core면 세 워크로드가 공존 가능하지만, 리소스 경합 방지를 위해 각 구성요소에 명시적 자원 상한을 둔다.

- k8s: 컨트롤플레인 1대(etcd 쿼럼 문제로 2노드 HA는 비권장) + 워커. 3번째 노드 합류 시 워커로 추가.
- MySQL: 호스트 OS에 네이티브 설치(systemd 서비스), 컨테이너/k8s 미사용. `/data/mysql`을 datadir로 사용. active/standby 복제 + 장애 시 전환 방식은 별도 결정 필요.
- KVM: libvirt로 관리, VM 디스크는 로컬 `/data`에 저장 (NAS 연동 전까지).

## 단계별 진행 순서 (하드웨어 확장 기준)

장비가 들어오는 순서대로 스테이지를 나눈다. **지금은 Stage 1(chan08, chan09 2대)만 구성한다.** 이후 장비가 실제로 도착/연결되면 해당 스테이지를 진행.

### Stage 1 — chan08 + chan09 2대만으로 구성 ✅ 전체 완료 (2026-08-24)

#### Phase 0 — 완료 ✅
- SSH 키 인증, sudo NOPASSWD, 기본 패키지/타임존/방화벽, `/data` 디스크 XFS 포맷·마운트
- 스크립트: `provision/` 디렉토리 (README.md 참고)

#### Phase 1 — 방화벽 재정리 ✅
- MySQL(3306), keepalived(vrrp) 포트 추가, 미사용 Calico 포트 제거
- 스크립트: `provision/05-firewall-stage1.sh`

#### Phase 2 — Kubernetes 클러스터 구축 (2노드) ✅
- containerd(SystemdCgroup) + kubeadm/kubelet/kubectl v1.36.4 설치, Flannel CNI
- chan08 컨트롤플레인, chan09 워커 — `kubeadm init/join` 완료, 둘 다 Ready
- **이슈**: UFW의 `DEFAULT_FORWARD_POLICY=DROP` 기본값이 pod→서비스 트래픽(iptables FORWARD 체인)을 막아 CoreDNS가 API 서버에 붙지 못하는 문제 발생. `ACCEPT`로 변경해 해결(인바운드 10.5.5.0/24 제한 규칙에는 영향 없음) — UFW를 쓰는 k8s 노드에서는 항상 이 설정을 함께 적용해야 함
- 스크립트: `k8s-cluster/` (01~06), 상세는 `k8s-cluster/README.md`

#### Phase 3 — MySQL active/standby (호스트 네이티브) ✅
- MySQL 8.0.46, `datadir=/data/mysql`, `innodb_buffer_pool_size=2G`
- semi-sync 복제 (chan08=source, chan09=replica), keepalived VIP `10.5.5.210`로 페일오버 — 양방향 전환 테스트 및 실데이터 복제 검증 완료
- 애플리케이션은 VIP로 접속. **레플리카 자동 승격은 하지 않음** — chan08 완전 장애 시엔 수동 승격 필요 (트래픽이 작고 운영자 상주 환경이라 이 정도로 충분하다고 판단)
- 스크립트: `mysql-ha/` (01~06), 상세는 `mysql-ha/README.md`

#### Phase 4 — KVM 기반 VM ✅
- libvirt/qemu-kvm 설치, `/data/vms`를 `data-pool` storage pool로 등록
- 실제 VM은 미생성 (워크로드 확정 시 진행)
- 스크립트: `kvm/01-setup-libvirt.sh`

---

### Stage 2 — 8G 메모리 소형 노드 추가

- k8s 워커로만 join (MySQL/VM은 배치하지 않음 — 리소스 부족)
- 클러스터 전체 워커 용량 확장 목적

### Stage 3 — GPU 머신 추가 (16G VRAM)

- k8s에 편입하지 않고 **독립 LLM 추론 서버**로 운영 (결정됨)
- 세부 서빙 스택/네트워크 노출 방식은 이 스테이지 진행 시점에 결정

### Stage 4 — Mac Studio 추가 (96G 통합메모리)

- k8s에 편입하지 않고 **독립 LLM 추론 서버**로 운영
- 세부 서빙 스택/네트워크 노출 방식은 이 스테이지 진행 시점에 결정

### Stage 5 — NAS 연동

- NAS 프로토콜(NFS/SMB/iSCSI) 및 용량 확인 후 연동
- k8s: NFS 기반 StorageClass로 공유 PV 제공
- MySQL/VM: 백업 타깃으로 전환

## 미결정 사항

Stage 1은 모두 결정/완료됨 (CNI=Flannel, 장애 전환=keepalived VIP). 남은 것:

- VM으로 옮길 구체적 워크로드 목록 (실제 VM 생성 시 필요)
- (Stage 3, 4) LLM 서빙 활용 방식 — 해당 스테이지 진행 시점에 결정
- (Stage 5) NAS 프로토콜/용량/접근 정보 — 해당 스테이지 진행 시점에 결정
