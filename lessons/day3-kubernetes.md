# Day 3 — Kubernetes, 앱을 올릴 무대 만들기

> [AI로 함께 만든 클러스터](../README.md) 시리즈

Kubernetes는 한마디로 "어떤 서버에 어떤 프로그램을 띄울지"를 대신 관리해주는 시스템입니다. 컨테이너 하나하나를 사람이 직접 어느 서버에 넣을지 정하고, 죽으면 다시 살리고, 트래픽이 몰리면 늘리는 일을 전부 자동으로 해줍니다. chan08을 클러스터 전체를 지휘하는 컨트롤플레인으로, chan09를 실제 앱이 도는 워커로 삼아 2대짜리 작은 클러스터를 만들었습니다.

설치 순서는 정해져 있습니다. 먼저 스왑을 꺼야 합니다. Kubernetes는 메모리 관리를 스스로 예측 가능하게 하기 위해 스왑이 켜져 있는 걸 허용하지 않습니다. 그다음 컨테이너를 실제로 실행하는 엔진인 containerd를 깔고, 클러스터를 구성하는 도구인 kubeadm과 각 노드의 에이전트인 kubelet, 명령줄 도구인 kubectl을 설치합니다. 준비가 끝나면 chan08에서 클러스터를 초기화하고, 노드끼리 통신할 가상 네트워크(Flannel)를 깔고, chan09가 그 클러스터에 합류(join)하면 끝입니다.

## 겪었던 문제 — CoreDNS가 몇 분째 "준비 안 됨" 상태로 멈춰있었다

문제는 이 마지막 단계에서 터졌습니다. 클러스터 내부에서 이름 해석을 담당하는 CoreDNS라는 파드가 몇 분이 지나도록 준비 완료 상태가 되지 않았습니다. 로그를 열어보니 "쿠버네티스 API에 연결하려고 계속 기다리는 중"이라는 메시지만 반복되고 있었습니다.

원인을 추적해보니 앞서 Day 1~2에서 켜둔 방화벽 때문이었습니다. 우분투는 UFW를 켜면 기본적으로 `DEFAULT_FORWARD_POLICY`라는 값을 DROP으로 설정하는데, 이건 "이 서버를 그냥 거쳐서 다른 곳으로 전달되는 트래픽"을 전부 막아버리는 설정입니다. 그런데 Kubernetes 파드끼리 주고받는 트래픽도, 겉보기엔 눈에 안 띄지만 정확히 이 경로를 지나갑니다. 결국 SSH 접속 같은 건 멀쩡했지만, 파드들이 서로 대화하는 통로만 조용히 막혀 있었던 셈입니다.

이 값을 ACCEPT로 바꾸고 방화벽을 다시 적용하자, CoreDNS를 포함한 모든 파드가 곧바로 정상 상태가 됐습니다. 외부에서 들어오는 접속을 막는 규칙(10.5.5.0/24 제한)은 전혀 건드리지 않고, 서버 내부에서 오가는 전달 트래픽에 대한 정책만 정확히 원인이 된 부분만 고쳤습니다.

두 노드가 모두 준비 완료 상태가 된 뒤, 클러스터 안에서 실제로 이름 해석이 되는지까지 테스트 파드를 하나 띄워서 확인했습니다.

## 이 단계에서 쓴 명령어

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

## 이 레슨에서 쓴 스크립트

[`scripts/k8s-cluster/`](../scripts/k8s-cluster/) — `01-prereqs.sh` → `02-containerd.sh` → `03-kube-packages.sh` → `04-init-control-plane.sh`(chan08) → `05-join-worker.sh`(chan09) → `06-fix-ufw-forward.sh`(위 문제 해결). 상세는 [`scripts/k8s-cluster/README.md`](../scripts/k8s-cluster/README.md) 참고.

---
◀ [Day 2 — 방화벽 재정리](day2-firewall.md) · [시리즈 목차](../README.md) · [Day 4 — MySQL 이중화](day4-mysql-ha.md) ▶
