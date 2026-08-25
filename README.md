# AI로 함께 만든 클러스터

아무것도 깔려 있지 않은 우분투 서버 두 대를, AI와 대화하면서 하나씩 실제로 동작하는 클러스터로 만들어가는 기록입니다. 1화(Stage 1)에서는 Kubernetes, MySQL 이중화, KVM 가상화까지 — 앞으로 뭘 올리든 버틸 수 있는 기반을 다졌습니다. 왜 이런 선택을 했는지, 어디서 막혔는지, 실제로 무슨 명령어를 쳤는지까지 가감 없이 남깁니다.

대상 서버: chan08(10.5.5.8) · chan09(10.5.5.9) · OS: Ubuntu 24.04 LTS · 작업일: 2026-08-24

## 완성된 그림

앱은 늘 하나의 가상 주소(VIP)로만 데이터베이스에 접속하고, 그 뒤에서 어느 서버가 실제로 쓰기를 담당하는지는 keepalived가 알아서 결정합니다. 두 서버는 Flannel이라는 가상 네트워크로 묶여서 하나의 Kubernetes 클러스터처럼 동작하고, 각자 KVM 저장소를 대기시켜뒀습니다.

```
                사내 앱 / 사용자
                       │
                       ▼
              VIP 10.5.5.210  (keepalived 가상 IP)
                       │  DB는 항상 이 주소로 접속
        ┌──────────────┴──────────────┐
        ▼                              ▼
  chan08 (10.5.5.8)              chan09 (10.5.5.9)
  - k8s 컨트롤플레인               - k8s 워커
  - MySQL source(주) ── semi-sync 복제 ──▶ MySQL replica(대기)
  - KVM data-pool(대기)            - KVM data-pool(대기)
  - /data (XFS 932G)               - /data (XFS 932G)

      └────────── Flannel 파드 네트워크로 서로 연결 ──────────┘
           (전체는 10.5.5.0/24 내부망 안에서만 통신)
```

## 시리즈 목차 (1화 — 기반 다지기)

| Day | 내용 | 스크립트 |
|---|---|---|
| [Day 1](lessons/day1-base-provisioning.md) | 서버가 나를 알아보게 만들기 (SSH, sudo, 패키지, 타임존, 디스크) | [`provision/`](provision/) |
| [Day 2](lessons/day2-firewall.md) | 방화벽, 미리 막고 필요한 것만 열기 | [`provision/05-firewall-stage1.sh`](provision/05-firewall-stage1.sh) |
| [Day 3](lessons/day3-kubernetes.md) | Kubernetes 클러스터 구축 (+ CoreDNS 장애 해결기) | [`k8s-cluster/`](k8s-cluster/) |
| [Day 4](lessons/day4-mysql-ha.md) | MySQL active/standby 이중화 (+ datadir 이전 장애 해결기) | [`mysql-ha/`](mysql-ha/) |
| [Day 5](lessons/day5-kvm.md) | KVM 하이퍼바이저 인프라 준비 | [`kvm/`](kvm/) |

한 번에 몰아서 읽고 싶다면 [`docs/infra-guide.md`](docs/infra-guide.md) 하나로도 전체를 볼 수 있습니다 (같은 내용을 한 페이지로 합친 버전).

## 저장소 구조

```
provision/      Day 1~2에서 쓴 서버 기본 프로비저닝 스크립트
k8s-cluster/     Day 3에서 쓴 Kubernetes 설치 스크립트
mysql-ha/        Day 4에서 쓴 MySQL 이중화 스크립트
kvm/             Day 5에서 쓴 KVM 인프라 스크립트
lessons/         레슨 형식 글 (day1~5)
docs/            한 페이지로 몰아본 버전 (infra-guide.md)
specs/           아키텍처 로드맵(overview.md)과 작업 진행 체크리스트(implementation-plan.md)
```

각 스크립트 디렉토리에는 스크립트가 무엇을 하는지, 어떤 순서로 실행하는지 설명하는 README.md가 함께 있습니다.

## 다음 화 예고

Stage 1은 chan08·chan09 두 대만으로 끝냈습니다. 앞으로 장비가 늘어날 때마다 이어집니다.

1. **8GB 소형 노드 추가** — Kubernetes 워커로만 합류 (자원이 작아 MySQL·VM은 올리지 않음)
2. **GPU 머신(16GB VRAM) 추가** — 클러스터에 넣지 않고 독립 LLM 추론 서버로 운영
3. **Mac Studio(96GB) 추가** — 마찬가지로 독립 LLM 추론 서버로 운영
4. **NAS 연동** — Kubernetes 공유 스토리지와 백업 대상으로 활용

자세한 로드맵과 아직 결정하지 않은 사항은 [`specs/overview.md`](specs/overview.md)에 있습니다.

## 참고 사항

- 서버가 속한 IP 대역(10.5.5.0/24)은 사설망(RFC1918)으로, 외부 인터넷에서 직접 접근할 수 없습니다.
- 실제 비밀번호·토큰·인증서는 이 저장소 어디에도 없습니다. `mysql-ha/03-generate-secrets.sh`가 만드는 값처럼, 필요한 비밀값은 실행 시점에 생성해 각 서버의 관리자 전용 위치에만 저장하고 로컬(이 저장소)에는 남기지 않는 방식으로 작업했습니다.
