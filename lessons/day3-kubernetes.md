# Day 3 — Kubernetes, 앱을 올릴 무대 만들기

> [Homelab Diary](../README.md) 시리즈

Kubernetes가 하는 일은 결국 하나입니다. 어떤 서버에 뭘 띄울지, 죽으면 어떻게 되살릴지를 사람 대신 관리해주는 것. chan08을 컨트롤플레인으로, chan09를 워커로 삼아 2노드짜리 작은 클러스터를 만들었습니다.

설치 순서는 정해져 있다시피 합니다. 스왑부터 꺼야 합니다 — Kubernetes는 스왑이 켜진 노드를 아예 받아주지 않습니다. `01-prereqs.sh`가 `swapoff -a`로 스왑을 끄고 fstab에서 관련 줄을 주석 처리한 뒤, 컨테이너 네트워킹에 필요한 `br_netfilter`·`overlay` 커널 모듈과 `net.ipv4.ip_forward=1` 같은 sysctl 값을 올립니다. `02-containerd.sh`는 컨테이너 런타임 containerd를 깔고 `SystemdCgroup = true`로 맞추고, `03-kube-packages.sh`가 kubeadm·kubelet·kubectl을 설치한 뒤 `apt-mark hold`로 버전을 고정합니다. k8s는 업그레이드에 정해진 절차가 있어서, apt가 실수로 올려버리면 곤란해집니다.

준비가 끝나면 `04-init-control-plane.sh`가 chan08에서 `kubeadm init --pod-network-cidr=10.244.0.0/16`으로 클러스터를 초기화하고 Flannel까지 설치합니다. `05-join-worker.sh`는 그 결과로 나온 join 토큰을 받아 chan09를 클러스터에 합류시킵니다. 여기까지는 순서대로 돌리면 끝나는 작업이었는데, CoreDNS가 발목을 잡았습니다.

두 노드 다 Ready는 떴는데 CoreDNS 파드만 몇 분째 준비 완료가 안 됐습니다. 로그는 "쿠버네티스 API 연결을 기다리는 중"이라는 말만 반복하고 있었고요. 범인은 Day 1~2에서 켜둔 UFW였습니다. 우분투는 UFW를 켜면 `DEFAULT_FORWARD_POLICY`를 기본값 DROP으로 놓는데, 이게 "이 서버를 그냥 거쳐가는" 트래픽을 전부 막아버립니다. SSH 접속은 멀쩡했으니 처음엔 방화벽을 의심하지도 않았는데, 파드끼리 주고받는 트래픽이 정확히 이 경로를 타고 있었던 겁니다. `06-fix-ufw-forward.sh`로 `/etc/default/ufw`의 이 값을 ACCEPT로 바꾸고 `ufw reload`하자 CoreDNS를 포함한 모든 파드가 바로 살아났습니다. 인바운드 규칙(10.5.5.0/24 제한)은 그대로 두고 FORWARD 체인만 정확히 건드린 셈입니다.

`kubectl get nodes -o wide`, `kubectl get pods -A`로 둘 다 정상인 걸 보고, 테스트 파드 하나 띄워서 `nslookup`까지 되는지 확인하고 마무리했습니다.

스크립트 6개의 순서와 각각 하는 일은 [`scripts/k8s-cluster/README.md`](../scripts/k8s-cluster/README.md)에 정리해뒀습니다.

---
◀ [Day 2 — 방화벽 재정리](day2-firewall.md) · [시리즈 목차](../README.md) · [Day 4 — MySQL 이중화](day4-mysql-ha.md) ▶
