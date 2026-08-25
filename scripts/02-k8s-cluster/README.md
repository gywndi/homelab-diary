# Kubernetes 클러스터 구축 (Stage 1, 2노드)

chan08(컨트롤플레인) + chan09(워커), CNI는 Flannel. Kubernetes v1.36.4 (dl.k8s.io stable 채널 기준 자동 선택).

## 스크립트 순서

### 1. `01-prereqs.sh` — Kubernetes가 요구하는 커널/네트워크 전제조건 충족
스왑 비활성화, `br_netfilter`/`overlay` 커널 모듈 로드, `net.ipv4.ip_forward=1` 등 sysctl 적용. 양쪽 노드 모두 실행.
```bash
sudo ./01-prereqs.sh
```

### 2. `02-containerd.sh` — 컨테이너 런타임 설치
containerd 설치 후 `SystemdCgroup = true`로 설정(kubelet의 cgroup 드라이버와 일치시킴). 양쪽 노드 모두 실행.
```bash
sudo ./02-containerd.sh
```

### 3. `03-kube-packages.sh` — kubeadm/kubelet/kubectl 설치
pkgs.k8s.io 저장소 등록 후 세 패키지 설치, `apt-mark hold`로 버전 고정. 양쪽 노드 모두 실행.
```bash
sudo ./03-kube-packages.sh
```

### 4. `04-init-control-plane.sh` — 컨트롤플레인 초기화 (chan08 전용)
`kubeadm init`으로 클러스터를 만들고 kubeconfig를 설정한 뒤 Flannel CNI를 설치하고 join 명령을 생성한다.
```bash
sudo ./04-init-control-plane.sh
```

### 5. `05-join-worker.sh` — 워커 합류 (chan09 전용)
`04`가 만든 `~/join-command.sh`를 이 서버의 홈 디렉터리에 미리 복사해둔 뒤 실행한다.
```bash
sudo ./05-join-worker.sh
```

### 6. `06-fix-ufw-forward.sh` — UFW FORWARD 정책 수정 (아래 "알려진 이슈" 참고)
`/etc/default/ufw`의 `DEFAULT_FORWARD_POLICY`를 `ACCEPT`로 바꾸고 `ufw reload`. 양쪽 노드 모두 실행.
```bash
sudo ./06-fix-ufw-forward.sh
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
