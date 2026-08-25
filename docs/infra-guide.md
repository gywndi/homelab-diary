# AI로 함께 만든 클러스터

### 1화 — 서버 두 대에 기반을 다지다

대상 서버: chan08(10.5.5.8) · chan09(10.5.5.9) · OS: Ubuntu 24.04 LTS · 작업일: 2026-08-24

이 시리즈는 아무것도 깔려 있지 않은 우분투 서버 두 대를, AI와 대화하면서 하나씩 실제로 동작하는 클러스터로 만들어가는 기록입니다. 1화에서는 Kubernetes, MySQL 이중화, KVM 가상화까지 — 앞으로 뭘 올리든 버틸 수 있는 기반을 다졌습니다. 왜 이런 선택을 했는지, 어디서 막혔는지, 실제로 무슨 명령어를 쳤는지까지 가감 없이 남깁니다.

---

## 시작하며

chan08과 chan09는 각각 32GB 메모리, 6코어짜리 평범한 서버입니다. 여기에 올릴 건 사내에서만 쓰는, 트래픽이 크지 않은 서비스들이었습니다. 그래서 처음부터 화려한 구성을 목표로 삼지 않았습니다. 대신 "적당히 튼튼하고, 나중에 무슨 일이 생겨도 이해할 수 있고, 장비가 늘어나면 자연스럽게 확장되는" 구조를 그렸습니다.

역할은 셋으로 나눴습니다. 컨테이너로 잘 돌아가는 일반적인 앱들은 Kubernetes에 맡기고, 데이터베이스는 k8s 밖에 독립적으로 세워서 클러스터가 흔들려도 데이터만큼은 안전하게 지키기로 했습니다. 그리고 컨테이너로 만들기 애매한 워크로드를 위해 KVM으로 진짜 가상머신을 띄울 수 있는 여지도 남겨뒀습니다. 세 가지를 굳이 다른 장비로 나누지 않고 같은 서버 두 대에 함께 올린 이유는 단순합니다 — 자원이 충분히 여유롭고, 장비를 늘릴 이유가 아직 없었기 때문입니다.

완성된 그림은 이렇습니다. 앱은 늘 하나의 가상 주소(VIP)로만 데이터베이스에 접속하고, 그 뒤에서 어느 서버가 실제로 쓰기를 담당하는지는 keepalived가 알아서 결정합니다. 두 서버는 Flannel이라는 가상 네트워크로 묶여서 하나의 Kubernetes 클러스터처럼 동작하고, 각자 KVM 저장소를 대기시켜뒀습니다.

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

---

## 1부 — 서버가 나를 알아보게 만들기

새로 설치한 서버는 매번 비밀번호를 물어보고, 관리자 권한도 없고, 방화벽도 다 잠겨 있습니다. 관리자가 상주하지 않는 서버 두 대를 스크립트로 반복해서 다루려면, 제일 먼저 이 장벽부터 허물어야 했습니다.

가장 먼저 SSH 키 인증이 걸려 있는지 확인했습니다. 비밀번호 없이 접속은 됐지만, 막상 관리자 권한(sudo)을 쓸 때마다 여전히 비밀번호를 물었습니다. 자동화 스크립트 안에서 비밀번호를 입력할 수는 없으니, chan 계정이 비밀번호 없이 sudo를 쓸 수 있도록 전용 설정 파일을 만들어 권한을 열었습니다.

권한이 확보된 다음엔 기본 살림살이를 갖췄습니다. 시스템 패키지를 최신으로 올리고, 타임존을 한국 시간으로 맞추고, 방화벽을 켜되 "일단 다 막고 필요한 것만 연다"는 원칙을 세웠습니다. 마침 1TB짜리 디스크 하나가 언마운트된 채로 놀고 있길래 확인해보니 이미 XFS로 포맷은 되어 있지만 비어 있는 상태였습니다. 그대로 `/data`에 마운트해서, 이후 MySQL 데이터와 가상머신 디스크가 전부 여기에 쌓이게 만들었습니다.

### 이 단계에서 쓴 명령어

- **`ssh -o BatchMode=yes 서버주소 명령어`** — 비밀번호 입력 없이 접속되는지 확인하는 용도로 처음부터 끝까지 계속 사용했습니다. `BatchMode=yes`는 만약 키 인증이 안 먹히면 비밀번호를 물어보는 대신 바로 실패시켜서, 스크립트가 멈춰버리는 대신 "안 됨"을 즉시 알 수 있게 해줍니다.
- **`echo "chan ALL=(ALL) NOPASSWD:ALL" | sudo visudo -f /etc/sudoers.d/90-chan-nopasswd`** — chan 계정이 비밀번호 없이 모든 sudo 명령을 쓸 수 있도록 권한 파일을 새로 만듭니다. 기존 `/etc/sudoers` 파일을 직접 고치지 않고 `sudoers.d` 아래 별도 파일로 추가하는 이유는, 문법 오류가 나도 원본 파일이 안전하고 나중에 이 권한만 따로 지우기도 쉽기 때문입니다. `visudo`를 거치면 저장 전에 문법을 자동으로 검사해줘서 실수로 시스템을 잠그는 사고를 막아줍니다.
- **`sudo apt-get update && sudo apt-get upgrade -y && sudo apt-get dist-upgrade -y`** — 패키지 목록을 최신화하고, 보안 패치를 포함한 전체 업데이트를 적용합니다. `dist-upgrade`는 일반 `upgrade`와 달리 커널 교체처럼 의존성이 복잡하게 바뀌는 업데이트까지 처리해줍니다.
- **`sudo timedatectl set-timezone Asia/Seoul`** — 서버 시간대를 한국 표준시로 맞춥니다. 로그 시간이 실제 사건이 벌어진 시간과 어긋나면 나중에 문제를 추적할 때 큰 혼란을 주기 때문에 가장 먼저 손대는 항목 중 하나입니다.
- **`sudo systemctl enable --now chrony`** — 시간 동기화 서비스를 켭니다. MySQL 복제나 인증서 검증처럼 여러 서버의 시계가 어긋나면 조용히 실패하는 기능들이 많아서, 시간 맞추기는 눈에 안 띄지만 꼭 필요한 작업입니다.
- **`sudo ufw default deny incoming` / `sudo ufw default allow outgoing`** — 방화벽의 기본 방침을 정합니다. 들어오는 연결은 원칙적으로 전부 막고, 나가는 연결은 허용해서 서버가 인터넷에서 패키지를 받아오는 데는 지장이 없게 합니다.
- **`sudo ufw allow from 10.5.5.0/24 to any port 22 proto tcp`** — SSH를 완전히 막지 않고, 우리 내부망(10.5.5.0/24)에서만 열어둡니다. 포트 자체를 여는 게 아니라 "어디서 오는 요청인지"까지 같이 지정하는 게 핵심입니다.
- **`sudo ufw enable`** — 지금까지 만든 규칙들을 실제로 켭니다. 방화벽을 켜는 순간부터 규칙에 없는 접속은 전부 끊기기 때문에, SSH 규칙이 제대로 들어갔는지 먼저 확인한 뒤에 실행했습니다.
- **`sudo mkfs.xfs -f /dev/sda2`** — 디스크를 XFS 파일시스템으로 포맷합니다. `-f`는 이미 파일시스템이 있어도 강제로 덮어쓰라는 옵션이라, 실행 전에 정말 비어 있는 디스크가 맞는지 두 번 확인했습니다.
- **`sudo blkid -s UUID -o value /dev/sda2`** — 방금 포맷한 디스크의 고유 식별자(UUID)를 알아냅니다. 디스크 이름(`/dev/sda2`)은 서버를 재부팅하면서 바뀔 수 있지만 UUID는 바뀌지 않기 때문에, 자동 마운트 설정에는 이 값을 씁니다.
- **`echo "UUID=... /data xfs defaults 0 2" >> /etc/fstab`** — 재부팅해도 이 디스크가 자동으로 `/data`에 마운트되도록 등록합니다. 이 줄이 없으면 서버를 재시작할 때마다 수동으로 마운트해야 합니다.
- **`sudo mount -a`** — 방금 `/etc/fstab`에 추가한 내용을 즉시 반영해서, 재부팅하지 않고도 `/data`가 바로 마운트되게 합니다.

---

## 2부 — 방화벽, 미리 막고 필요한 것만 열기

방화벽은 처음부터 "일단 다 막고, 쓸 것만 하나씩 연다"는 원칙으로 접근했습니다. 외부 인터넷에서는 이 서버들에 접근할 이유가 전혀 없는 내부용 서비스였기 때문에, 같은 내부망(10.5.5.0/24) 밖에서 오는 요청은 아예 존재하지 않는 것처럼 취급했습니다.

다만 처음 방화벽을 설정할 때는 아직 Kubernetes에 어떤 네트워크 방식(CNI)을 쓸지 정하기 전이었습니다. 그래서 후보로 검토하던 두 가지 방식(Flannel과 Calico)이 각각 쓰는 포트를 일단 다 열어뒀다가, 나중에 Flannel로 확정되고 나서 쓰지 않는 Calico 쪽 포트를 다시 닫았습니다. MySQL과 keepalived를 도입할 때도 마찬가지로 그 시점에 필요해진 포트(3306, VRRP)를 추가했습니다. 방화벽 규칙은 한 번 정하고 끝나는 게 아니라, 결정이 바뀔 때마다 같이 정리해줘야 한다는 걸 이 과정에서 체감했습니다.

### 이 단계에서 쓴 명령어

- **`sudo ufw allow from 10.5.5.0/24 to any port 6443 proto tcp`** — Kubernetes API 서버 포트를 내부망에서만 열어둡니다. 이 포트가 막혀 있으면 `kubectl` 명령 자체가 클러스터에 닿지 못합니다.
- **`sudo ufw allow from 10.5.5.0/24 to any port 10250 proto tcp`** — kubelet(각 노드에서 실제로 컨테이너를 관리하는 에이전트) 포트를 엽니다. 컨트롤플레인이 각 노드 상태를 확인하고 명령을 내릴 때 이 포트를 씁니다.
- **`sudo ufw allow from 10.5.5.0/24 to any port 8472 proto udp`** — Flannel이 노드 사이에 가상 네트워크(VXLAN)를 만들 때 쓰는 포트입니다. 이게 막혀 있으면 서로 다른 서버에 있는 파드끼리 통신할 수 없습니다.
- **`sudo ufw allow from 10.5.5.0/24 to any port 3306 proto tcp`** — MySQL 접속 포트입니다. 애플리케이션과 복제 트래픽이 모두 이 포트를 지나갑니다.
- **`sudo ufw allow from 10.5.5.0/24 proto vrrp`** — keepalived가 "내가 살아있다"는 신호를 서로 주고받을 때 쓰는 VRRP 프로토콜을 허용합니다. 이 신호가 막히면 두 서버가 서로 상대가 죽은 줄 알고 동시에 가상 IP를 자기 것이라 주장하는 사고가 날 수 있습니다.
- **`sudo ufw delete allow ...`** — 더 이상 쓰지 않기로 한 규칙(Calico용 포트 등)을 지웁니다. 안 쓰는 포트를 열어두는 건 그 자체로 불필요한 위험이라, 결정이 바뀔 때마다 바로 정리했습니다.

---

## 3부 — Kubernetes, 앱을 올릴 무대 만들기

Kubernetes는 한마디로 "어떤 서버에 어떤 프로그램을 띄울지"를 대신 관리해주는 시스템입니다. 컨테이너 하나하나를 사람이 직접 어느 서버에 넣을지 정하고, 죽으면 다시 살리고, 트래픽이 몰리면 늘리는 일을 전부 자동으로 해줍니다. chan08을 클러스터 전체를 지휘하는 컨트롤플레인으로, chan09를 실제 앱이 도는 워커로 삼아 2대짜리 작은 클러스터를 만들었습니다.

설치 순서는 정해져 있습니다. 먼저 스왑을 꺼야 합니다. Kubernetes는 메모리 관리를 스스로 예측 가능하게 하기 위해 스왑이 켜져 있는 걸 허용하지 않습니다. 그다음 컨테이너를 실제로 실행하는 엔진인 containerd를 깔고, 클러스터를 구성하는 도구인 kubeadm과 각 노드의 에이전트인 kubelet, 명령줄 도구인 kubectl을 설치합니다. 준비가 끝나면 chan08에서 클러스터를 초기화하고, 노드끼리 통신할 가상 네트워크(Flannel)를 깔고, chan09가 그 클러스터에 합류(join)하면 끝입니다.

문제는 이 마지막 단계에서 터졌습니다. 클러스터 내부에서 이름 해석을 담당하는 CoreDNS라는 파드가 몇 분이 지나도록 준비 완료 상태가 되지 않았습니다. 로그를 열어보니 "쿠버네티스 API에 연결하려고 계속 기다리는 중"이라는 메시지만 반복되고 있었습니다. 원인을 추적해보니 앞서 1부에서 켜둔 방화벽 때문이었습니다. 우분투는 UFW를 켜면 기본적으로 `DEFAULT_FORWARD_POLICY`라는 값을 DROP으로 설정하는데, 이건 "이 서버를 그냥 거쳐서 다른 곳으로 전달되는 트래픽"을 전부 막아버리는 설정입니다. 그런데 Kubernetes 파드끼리 주고받는 트래픽도, 겉보기엔 눈에 안 띄지만 정확히 이 경로를 지나갑니다. 결국 SSH 접속 같은 건 멀쩡했지만, 파드들이 서로 대화하는 통로만 조용히 막혀 있었던 셈입니다. 이 값을 ACCEPT로 바꾸고 방화벽을 다시 적용하자, CoreDNS를 포함한 모든 파드가 곧바로 정상 상태가 됐습니다. 외부에서 들어오는 접속을 막는 규칙(10.5.5.0/24 제한)은 전혀 건드리지 않고, 서버 내부에서 오가는 전달 트래픽에 대한 정책만 정확히 원인이 된 부분만 고쳤습니다.

두 노드가 모두 준비 완료 상태가 된 뒤, 클러스터 안에서 실제로 이름 해석이 되는지까지 테스트 파드를 하나 띄워서 확인했습니다.

### 이 단계에서 쓴 명령어

- **`sudo swapoff -a`** — 현재 켜져 있는 스왑을 즉시 끕니다. Kubernetes가 메모리 압박 상황을 예측 가능하게 다루기 위해 요구하는 사전 조건입니다.
- **`sed -i -E '/\sswap\s/ s/^([^#])/#\1/' /etc/fstab`** — `/etc/fstab`에서 스왑 관련 줄을 찾아 앞에 `#`을 붙여 주석 처리합니다. 이렇게 해두지 않으면 서버가 재부팅될 때 스왑이 다시 켜져 버립니다.
- **`sudo modprobe overlay` / `sudo modprobe br_netfilter`** — 컨테이너가 쓰는 계층형 파일시스템(overlay)과, 브리지 네트워크를 지나는 패킷을 iptables가 검사할 수 있게 해주는 커널 모듈(br_netfilter)을 즉시 활성화합니다. 이 모듈들이 없으면 컨테이너 네트워킹 자체가 제대로 동작하지 않습니다.
- **`sysctl net.bridge.bridge-nf-call-iptables=1`, `net.ipv4.ip_forward=1` 등을 `/etc/sysctl.d/`에 등록 후 `sysctl --system`** — 브리지를 지나는 트래픽을 iptables 규칙이 검사하도록 하고, 서버가 패킷을 다른 곳으로 전달(forward)할 수 있게 커널 설정을 바꿉니다. 재부팅 후에도 유지되도록 설정 파일로 저장해둡니다.
- **`sudo apt-get install containerd`** — 컨테이너를 실제로 실행하는 런타임을 설치합니다. kubelet은 스스로 컨테이너를 실행하지 않고 containerd 같은 런타임에 지시만 내립니다.
- **`containerd config default > /etc/containerd/config.toml` 후 `SystemdCgroup = true`로 수정, `systemctl restart containerd`** — containerd의 기본 설정 파일을 만들고, 리눅스의 자원 관리 방식(cgroup)을 systemd와 맞춰줍니다. 이 설정이 kubelet의 방식과 다르면 노드가 불안정해지는 경우가 있어 필수로 맞춰야 하는 부분입니다.
- **`curl -fsSL https://pkgs.k8s.io/.../Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg`** — Kubernetes 공식 패키지 저장소의 서명 키를 받아옵니다. 이 키가 있어야 apt가 이 저장소에서 받은 패키지가 위변조되지 않았다는 걸 검증할 수 있습니다.
- **`sudo apt-get install kubelet kubeadm kubectl` 후 `sudo apt-mark hold kubelet kubeadm kubectl`** — 클러스터를 구성하고 운영하는 데 필요한 세 도구를 설치합니다. `apt-mark hold`는 이후 일반적인 시스템 업데이트에서 이 세 패키지만 자동으로 버전이 올라가지 않도록 고정하는 명령인데, Kubernetes는 버전을 올릴 때 정해진 절차를 따라야 하므로 실수로 업그레이드되는 걸 막기 위한 안전장치입니다.
- **`sudo kubeadm init --apiserver-advertise-address=10.5.5.8 --pod-network-cidr=10.244.0.0/16`** — chan08을 클러스터의 컨트롤플레인으로 초기화하는 핵심 명령입니다. `--pod-network-cidr`은 파드들에게 나눠줄 내부 IP 대역을 미리 정해두는 옵션으로, 이후 설치할 Flannel의 기본값과 맞춰줘야 합니다.
- **`mkdir -p ~/.kube && cp /etc/kubernetes/admin.conf ~/.kube/config`** — 클러스터를 초기화하면서 만들어진 관리자 인증서를 일반 계정(chan)이 쓸 수 있는 위치로 복사합니다. 이 파일이 있어야 `sudo` 없이 `kubectl` 명령이 클러스터에 접속할 수 있습니다.
- **`kubectl apply -f https://.../kube-flannel.yml`** — Flannel을 클러스터에 설치합니다. 이 순간부터 서로 다른 서버에 있는 파드들이 마치 같은 네트워크에 있는 것처럼 통신할 수 있게 됩니다.
- **`kubeadm token create --print-join-command`** — 다른 노드가 이 클러스터에 합류할 때 쓸 수 있는 일회용 토큰과 명령어를 생성합니다. 이 값은 클러스터의 신원을 증명하는 역할을 하기 때문에 신중하게 다뤄야 합니다.
- **`sudo kubeadm join 10.5.5.8:6443 --token ... --discovery-token-ca-cert-hash ...`** — chan09에서 실행해서, 방금 만든 토큰으로 이 노드를 클러스터의 워커로 합류시킵니다.
- **`sed -i 's/DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw` 후 `sudo ufw reload`** — 앞서 설명한 CoreDNS 장애의 실제 해결책입니다. 방화벽이 서버 내부를 그냥 지나가는 트래픽까지 막지 않도록 정책을 바꾸고 즉시 반영합니다.
- **`kubectl get nodes -o wide` / `kubectl get pods -A`** — 지금까지의 작업이 실제로 잘 됐는지 확인하는 가장 기본적인 명령입니다. 노드가 전부 `Ready` 상태인지, 시스템 파드가 전부 `Running`인지를 이 두 명령으로 계속 지켜봤습니다.

---

## 4부 — MySQL 이중화, 하나가 죽어도 안 멈추게

데이터베이스는 잃어버리면 안 되는 자산이라, k8s 안에 넣지 않고 서버에 직접 설치했습니다. chan08을 실제로 쓰기가 일어나는 source로, chan09를 계속 복제만 받는 replica로 두고, 그 둘 사이를 가상 IP(VIP)로 연결해서 애플리케이션은 어느 쪽이 진짜 source인지 신경 쓸 필요 없이 항상 같은 주소로만 접속하면 되도록 만들었습니다.

복제 방식은 semi-sync를 선택했습니다. 완전 비동기 복제는 source가 갑자기 죽는 순간 아직 복제되지 않은 마지막 몇 건의 데이터가 사라질 위험이 있고, 반대로 완전 동기(그룹 복제 같은) 방식은 그만큼 설정과 운영이 훨씬 복잡해집니다. semi-sync는 "적어도 한 대는 확실히 데이터를 받았다는 응답을 받은 뒤에야 커밋을 완료 처리"하는 방식이라, 복잡도 대비 안정성이 좋은 절충안이었습니다. 장애 전환 방식도 비슷한 고민을 거쳤습니다. Orchestrator 같은 자동 승격 도구는 강력하지만 배우고 운영할 게 많습니다. 트래픽이 크지 않고 사람이 바로 대응할 수 있는 규모라, "장애가 감지되면 가상 IP만 자동으로 살아있는 쪽으로 옮겨주고, 진짜 쓰기 권한을 넘기는 승격은 사람이 최종 판단"하는 가벼운 방식(keepalived)을 골랐습니다.

여기서도 한 번 걸려 넘어졌습니다. 데이터 폴더를 `/var/lib/mysql`에서 `/data/mysql`로 옮기는 스크립트를 돌렸는데, MySQL이 시작하자마자 몇 초 간격으로 계속 죽었다 켜지길 반복했습니다. 로그에는 "data dir not found"라는 오류만 찍혀 있었습니다. 원인을 찾아보니, 설정 파일에서 datadir이 적힌 줄을 자동으로 바꾸려던 명령이 조용히 실패하고 있었습니다. 우분투 기본 설정 파일에는 이 줄이 `#`으로 이미 주석 처리된 채로 들어 있었는데, "값을 바꾸는" 방식의 명령은 이 줄을 찾지 못하면 에러 없이 그냥 아무 일도 하지 않고 넘어가 버립니다. 그 결과 MySQL은 이미 옮겨서 사라진 원래 경로(`/var/lib/mysql`)를 계속 찾다가 실패하고 있었던 겁니다. 기존 줄을 억지로 고치려 하지 않고, 새 설정 파일을 하나 더 만들어서 거기에 새 경로를 명확하게 적는 방식으로 우회했습니다. MySQL은 설정 파일들을 이름 순서대로 읽고 나중에 읽은 파일이 앞선 값을 덮어쓰기 때문에, 이 방법을 쓰면 기존 줄이 주석인지 아닌지 신경 쓸 필요 없이 항상 확실하게 적용됩니다.

설정만 해두고 끝내지 않고, 실제로 chan08의 MySQL을 강제로 멈춰서 가상 IP가 chan09로 정말 넘어가는지, 다시 살렸을 때 원래대로 돌아오는지까지 검증했습니다. 정지시키고 약 6초 만에 VIP가 chan09로 이동했고, 다시 켜자 우선순위 설정(chan08 150 > chan09 100)에 따라 VIP가 chan08로 돌아왔습니다. 다만 복제 연결은 기본적으로 60초 간격으로 재시도하도록 되어 있어서, 곧바로 이어지길 원한다면 복제 IO 스레드를 수동으로 한 번 재시작해줘야 했습니다. 이 구성이 자동으로 해주는 건 딱 거기까지입니다 — 가상 IP를 살아있는 서버로 옮겨주는 것. chan08이 완전히 죽어버리는 진짜 재해 상황에서는, chan09를 실제로 쓰기가 가능한 새로운 source로 승격하는 건 여전히 사람이 판단해서 해야 합니다. 트래픽이 작고 사람이 바로 대응 가능한 지금 규모에서는 이 정도가 딱 맞는 균형점이라고 봤습니다.

### 이 단계에서 쓴 명령어

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

---

## 5부 — KVM, 언제든 VM을 띄울 수 있는 상태 만들기

Kubernetes로 옮기기 애매한 워크로드, 이를테면 특정 운영체제가 필요하거나 컨테이너화가 안 되는 소프트웨어를 위한 비상구도 미리 만들어뒀습니다. 지금 당장 띄울 가상머신은 없었기 때문에, 실제 VM을 만드는 대신 "필요할 때 바로 만들 수 있는 상태"까지만 준비했습니다. KVM과 libvirt를 설치하고, `/data` 디스크 안에 가상머신 전용 저장 공간을 만들어 등록해뒀습니다.

여기서는 사소하지만 헷갈리는 순간이 하나 있었습니다. 분명 저장 공간을 만들었는데, 확인 명령을 치면 아무것도 안 보였습니다. 알고 보니 관리자 권한으로 만든 저장 공간은 시스템 전체가 함께 쓰는 영역(`qemu:///system`)에 등록되는데, 일반 계정으로 그냥 확인 명령을 실행하면 그 계정만 쓰는 별도의 영역(`qemu:///session`)을 기본으로 들여다봅니다. 데이터가 사라진 게 아니라 서로 다른 곳을 보고 있었던 것뿐이었습니다. chan 계정이 기본적으로 시스템 전체 영역을 보도록 설정을 하나 추가해서, 앞으로는 헷갈릴 일 없이 바로 확인할 수 있게 정리했습니다.

### 이 단계에서 쓴 명령어

- **`sudo apt-get install qemu-kvm libvirt-daemon-system libvirt-clients virtinst bridge-utils`** — 가상머신을 실제로 실행하는 하이퍼바이저(qemu-kvm)와 이를 관리하는 데몬(libvirt), 가상머신을 만들 때 쓰는 도구들을 설치합니다.
- **`sudo usermod -aG libvirt,kvm chan`** — chan 계정을 libvirt·kvm 그룹에 추가해서, 매번 `sudo`를 붙이지 않고도 가상머신을 관리할 수 있게 합니다.
- **`sudo systemctl enable --now libvirtd`** — 가상머신을 관리하는 핵심 데몬을 켜고, 서버가 재부팅돼도 자동으로 다시 켜지도록 등록합니다.
- **`virsh pool-define-as data-pool dir --target /data/vms`** — `/data/vms` 폴더를 "data-pool"이라는 이름의 저장 공간으로 libvirt에 등록합니다. 앞으로 만들 가상머신의 디스크 이미지는 전부 이 안에 저장됩니다.
- **`virsh pool-build data-pool` / `virsh pool-start data-pool` / `virsh pool-autostart data-pool`** — 등록한 저장 공간을 실제로 만들고(build), 사용 가능한 상태로 켜고(start), 서버가 재부팅돼도 자동으로 다시 켜지도록(autostart) 설정하는 세 단계입니다.
- **`echo 'uri_default = "qemu:///system"' > ~/.config/libvirt/libvirt.conf`** — 앞서 설명한 "저장 공간이 안 보이는" 문제의 해결책입니다. chan 계정이 `virsh` 명령을 실행할 때 기본적으로 바라보는 대상을 시스템 전체 영역으로 고정합니다.

---

## 마치며 — 1화를 마치고

chan08과 chan09 두 대만으로 Kubernetes 클러스터, MySQL 이중화, KVM 기반까지 전부 완료하고, 실제로 장애 상황까지 재현해서 검증하는 데까지 왔습니다. 중간에 만난 두 번의 문제(방화벽이 파드 통신을 막았던 것, 주석 처리된 설정 줄 때문에 datadir 변경이 조용히 실패했던 것) 모두 겉으로 보이는 증상과 실제 원인이 한 걸음 떨어져 있었다는 공통점이 있습니다. 로그를 끝까지 읽고, 왜 그런 증상이 나오는지 거슬러 올라가는 과정이 결국 가장 확실한 지름길이었습니다.

다음 화부터는 장비가 늘어날 때마다 이어집니다. 메모리 8GB짜리 소형 노드가 들어오면 Kubernetes 워커로만 합류시키고, GPU 머신(16GB VRAM)과 Mac Studio(96GB)가 들어오면 클러스터에 넣지 않고 각각 독립된 LLM 추론 서버로 운영할 계획입니다. NAS가 연결되면 그때 클러스터의 공유 스토리지와 백업 대상으로 활용할 예정입니다.
