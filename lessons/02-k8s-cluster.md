# Kubernetes 클러스터 구축 (Stage 1, 2노드)

chan08(컨트롤플레인) + chan09(워커), CNI는 Flannel. Kubernetes v1.36.4 (dl.k8s.io stable 채널 기준 자동 선택).

## 스크립트 순서

### 1. [`01-prereqs.sh`](../scripts/02-k8s-cluster/01-prereqs.sh) — Kubernetes가 요구하는 커널/네트워크 전제조건 충족 (양쪽 노드)
```bash
# 지금 켜져 있는 스왑을 즉시 끄기 (k8s는 스왑 켜진 노드를 허용 안 함)
sudo swapoff -a

# 재부팅해도 스왑이 다시 켜지지 않도록 fstab의 스왑 줄 주석 처리
sudo sed -i -E '/\sswap\s/ s/^([^#])/#\1/' /etc/fstab

# 컨테이너가 쓰는 계층형 파일시스템 모듈 로드
sudo modprobe overlay

# 브리지 트래픽을 iptables가 검사할 수 있게 해주는 모듈 로드
sudo modprobe br_netfilter
```
`/etc/sysctl.d/k8s.conf`에 아래 세 줄을 추가한 뒤 반영:
```bash
# 브리지를 지나는 IPv4 트래픽을 iptables 규칙 대상에 포함
net.bridge.bridge-nf-call-iptables  = 1

# 브리지를 지나는 IPv6 트래픽도 동일하게 포함
net.bridge.bridge-nf-call-ip6tables = 1

# 이 서버가 패킷을 다른 목적지로 전달(forward)할 수 있게 허용
net.ipv4.ip_forward                 = 1
```
```bash
# 방금 추가한 sysctl 설정 파일들을 즉시 반영
sudo sysctl --system
```

### 2. [`02-containerd.sh`](../scripts/02-k8s-cluster/02-containerd.sh) — 컨테이너 런타임 설치 (양쪽 노드)
```bash
# 컨테이너 런타임 설치
sudo apt-get install -y containerd

# containerd 기본 설정 파일 생성
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null

# cgroup 드라이버를 systemd로 맞춤 (kubelet 기본값과 일치시켜야 함)
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# 변경한 설정을 반영하기 위해 재시작
sudo systemctl restart containerd
```

### 3. [`03-kube-packages.sh`](../scripts/02-k8s-cluster/03-kube-packages.sh) — kubeadm/kubelet/kubectl 설치 (양쪽 노드, v1.36 기준)
```bash
# Kubernetes 공식 저장소 서명 키를 받아와 등록 (패키지 위변조 검증용)
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key" \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# apt 저장소 목록에 Kubernetes repo 추가
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list

# 방금 추가한 저장소를 포함해 패키지 목록 갱신
sudo apt-get update -y

# 클러스터 구성/운영 도구 설치
sudo apt-get install -y kubelet kubeadm kubectl

# 일반 시스템 업데이트로 버전이 자동으로 올라가지 않도록 고정
sudo apt-mark hold kubelet kubeadm kubectl
```

### 4. [`04-init-control-plane.sh`](../scripts/02-k8s-cluster/04-init-control-plane.sh) — 컨트롤플레인 초기화 (chan08 전용)
```bash
# 컨트롤플레인 초기화. 파드에 나눠줄 내부 IP 대역을 Flannel 기본값에 맞춤
sudo kubeadm init \
  --apiserver-advertise-address=10.5.5.8 \
  --pod-network-cidr=10.244.0.0/16

# kubectl 설정 디렉터리 생성
mkdir -p ~/.kube

# 초기화 시 생성된 관리자 인증서를 일반 계정이 쓸 위치로 복사
sudo cp -i /etc/kubernetes/admin.conf ~/.kube/config

# sudo 없이 kubectl을 쓸 수 있도록 소유자 변경
sudo chown chan:chan ~/.kube/config

# Flannel CNI 설치 — 이 순간부터 서로 다른 노드의 파드끼리 통신 가능
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# 워커가 합류할 때 쓸 일회용 토큰과 join 명령 생성
kubeadm token create --print-join-command
```

### 5. [`05-join-worker.sh`](../scripts/02-k8s-cluster/05-join-worker.sh) — 워커 합류 (chan09 전용)
`04`의 마지막 명령이 출력한 join 명령을 그대로 실행한다 (토큰과 해시는 실행할 때마다 새로 생성됨).
```bash
# chan08이 출력한 토큰/해시로 이 노드를 클러스터에 워커로 합류시킴
sudo kubeadm join 10.5.5.8:6443 \
  --token <생성된 토큰> \
  --discovery-token-ca-cert-hash sha256:<해시>
```

### 6. [`06-fix-ufw-forward.sh`](../scripts/02-k8s-cluster/06-fix-ufw-forward.sh) — UFW FORWARD 정책 수정 (아래 "알려진 이슈" 참고, 양쪽 노드)
```bash
# 서버를 그냥 거쳐가는(FORWARD) 트래픽까지 막던 기본 정책을 ACCEPT로 변경
sudo sed -i 's/^DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

# 변경한 정책 즉시 반영
sudo ufw reload
```

## 알려진 이슈: UFW가 pod 네트워크를 막음

[`04-firewall.sh`](../scripts/01-provision/04-firewall.sh)로 UFW를 활성화하면 `/etc/default/ufw`의 `DEFAULT_FORWARD_POLICY`가 기본 `DROP`으로 설정된다. 이 상태에서는 iptables `FORWARD` 체인 기본 정책이 DROP이 되어, kube-proxy/Flannel이 만든 규칙에 명시적으로 걸리지 않는 pod→ClusterIP 트래픽이 막힌다. 실제로 CoreDNS가 `[WARNING] plugin/kubernetes: starting server with unsynced Kubernetes API` 상태에서 멈추는 증상으로 나타났다.

`06-fix-ufw-forward.sh`가 `DEFAULT_FORWARD_POLICY`를 `ACCEPT`로 바꾸고 `ufw reload`한다. **인바운드 규칙(10.5.5.0/24 제한)에는 영향 없음** — FORWARD 체인(라우팅되는 트래픽)만 대상. 앞으로 이 서버들에 UFW를 다시 초기화하는 경우 이 스크립트를 반드시 함께 적용해야 한다.

## 검증

```bash
kubectl get nodes -o wide         # chan08, chan09 모두 Ready

kubectl get pods -A               # kube-system, kube-flannel 전부 1/1 Running

kubectl run dns-test --image=busybox:1.36 --restart=Never --command -- sleep 3600

kubectl exec dns-test -- nslookup kubernetes.default.svc.cluster.local

kubectl delete pod dns-test
```

kubeconfig는 chan08의 `~/.kube/config`에 있음 (작업 계정용, `kubectl`은 chan08에서 바로 사용 가능).
