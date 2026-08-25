# Day 2 — 방화벽, 미리 막고 필요한 것만 열기

> [AI로 함께 만든 클러스터](../README.md) 시리즈

방화벽은 처음부터 "일단 다 막고, 쓸 것만 하나씩 연다"는 원칙으로 접근했습니다. 외부 인터넷에서는 이 서버들에 접근할 이유가 전혀 없는 내부용 서비스였기 때문에, 같은 내부망(10.5.5.0/24) 밖에서 오는 요청은 아예 존재하지 않는 것처럼 취급했습니다.

다만 처음 방화벽을 설정할 때는 아직 Kubernetes에 어떤 네트워크 방식(CNI)을 쓸지 정하기 전이었습니다. 그래서 후보로 검토하던 두 가지 방식(Flannel과 Calico)이 각각 쓰는 포트를 일단 다 열어뒀다가, 나중에 Flannel로 확정되고 나서 쓰지 않는 Calico 쪽 포트를 다시 닫았습니다. MySQL과 keepalived를 도입할 때도 마찬가지로 그 시점에 필요해진 포트(3306, VRRP)를 추가했습니다. 방화벽 규칙은 한 번 정하고 끝나는 게 아니라, 결정이 바뀔 때마다 같이 정리해줘야 한다는 걸 이 과정에서 체감했습니다.

## 이 단계에서 쓴 명령어

- **`sudo ufw allow from 10.5.5.0/24 to any port 6443 proto tcp`** — Kubernetes API 서버 포트를 내부망에서만 열어둡니다. 이 포트가 막혀 있으면 `kubectl` 명령 자체가 클러스터에 닿지 못합니다.
- **`sudo ufw allow from 10.5.5.0/24 to any port 10250 proto tcp`** — kubelet(각 노드에서 실제로 컨테이너를 관리하는 에이전트) 포트를 엽니다. 컨트롤플레인이 각 노드 상태를 확인하고 명령을 내릴 때 이 포트를 씁니다.
- **`sudo ufw allow from 10.5.5.0/24 to any port 8472 proto udp`** — Flannel이 노드 사이에 가상 네트워크(VXLAN)를 만들 때 쓰는 포트입니다. 이게 막혀 있으면 서로 다른 서버에 있는 파드끼리 통신할 수 없습니다.
- **`sudo ufw allow from 10.5.5.0/24 to any port 3306 proto tcp`** — MySQL 접속 포트입니다. 애플리케이션과 복제 트래픽이 모두 이 포트를 지나갑니다.
- **`sudo ufw allow from 10.5.5.0/24 proto vrrp`** — keepalived가 "내가 살아있다"는 신호를 서로 주고받을 때 쓰는 VRRP 프로토콜을 허용합니다. 이 신호가 막히면 두 서버가 서로 상대가 죽은 줄 알고 동시에 가상 IP를 자기 것이라 주장하는 사고가 날 수 있습니다.
- **`sudo ufw delete allow ...`** — 더 이상 쓰지 않기로 한 규칙(Calico용 포트 등)을 지웁니다. 안 쓰는 포트를 열어두는 건 그 자체로 불필요한 위험이라, 결정이 바뀔 때마다 바로 정리했습니다.

## 이 레슨에서 쓴 스크립트

[`provision/05-firewall-stage1.sh`](../provision/05-firewall-stage1.sh) — MySQL/keepalived 포트 추가, 안 쓰는 Calico 포트 제거. Day 1의 초기 방화벽(`provision/04-firewall.sh`)에 이어 적용됩니다.

---
◀ [Day 1 — 서버 기본 준비](day1-base-provisioning.md) · [시리즈 목차](../README.md) · [Day 3 — Kubernetes](day3-kubernetes.md) ▶
