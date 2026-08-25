# Kubernetes 클러스터 구축 (Stage 1, 2노드)

chan08(컨트롤플레인) + chan09(워커), CNI는 Flannel. Kubernetes v1.36.4 (dl.k8s.io stable 채널 기준 자동 선택).

## 스크립트 순서

### 1. `01-prereqs.sh` — Kubernetes가 요구하는 커널/네트워크 전제조건 충족 (양쪽 노드)
```bash
sudo swapoff -a
sudo sed -i -E '/\sswap\s/ s/^([^#])/#\1/' /etc/fstab
sudo modprobe overlay
sudo modprobe br_netfilter
```
`/etc/sysctl.d/k8s.conf`에 아래 세 줄을 추가한 뒤 반영:
```bash
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
```
```bash
sudo sysctl --system
```

### 2. `02-containerd.sh` — 컨테이너 런타임 설치 (양쪽 노드)
```bash
sudo apt-get install -y containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
```

### 3. `03-kube-packages.sh` — kubeadm/kubelet/kubectl 설치 (양쪽 노드, v1.36 기준)
```bash
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update -y
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

### 4. `04-init-control-plane.sh` — 컨트롤플레인 초기화 (chan08 전용)
```bash
sudo kubeadm init --apiserver-advertise-address=10.5.5.8 --pod-network-cidr=10.244.0.0/16
mkdir -p ~/.kube
sudo cp -i /etc/kubernetes/admin.conf ~/.kube/config
sudo chown chan:chan ~/.kube/config
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
kubeadm token create --print-join-command
```

### 5. `05-join-worker.sh` — 워커 합류 (chan09 전용)
`04`의 마지막 명령이 출력한 join 명령을 그대로 실행한다 (토큰과 해시는 실행할 때마다 새로 생성됨).
```bash
sudo kubeadm join 10.5.5.8:6443 --token <생성된 토큰> --discovery-token-ca-cert-hash sha256:<해시>
```

### 6. `06-fix-ufw-forward.sh` — UFW FORWARD 정책 수정 (아래 "알려진 이슈" 참고, 양쪽 노드)
```bash
sudo sed -i 's/^DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
sudo ufw reload
```

## 알려진 이슈: UFW가 pod 네트워크를 막음

`../01-provision/04-firewall.sh`로 UFW를 활성화하면 `/etc/default/ufw`의 `DEFAULT_FORWARD_POLICY`가 기본 `DROP`으로 설정된다. 이 상태에서는 iptables `FORWARD` 체인 기본 정책이 DROP이 되어, kube-proxy/Flannel이 만든 규칙에 명시적으로 걸리지 않는 pod→ClusterIP 트래픽이 막힌다. 실제로 CoreDNS가 `[WARNING] plugin/kubernetes: starting server with unsynced Kubernetes API` 상태에서 멈추는 증상으로 나타났다.

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
