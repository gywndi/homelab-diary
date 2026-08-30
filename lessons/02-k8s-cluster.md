# Kubernetes 클러스터 구축 (Stage 1, 2노드)

chan08(컨트롤플레인) + chan09(워커), CNI는 Flannel. Kubernetes v1.36.4 (dl.k8s.io stable 채널 기준 자동 선택).

## 목적

2노드 k8s 클러스터의 기본 골격을 만든다. 컨트롤플레인은 처음부터 keepalived VIP(10.5.5.3)를 공유 진입점(`controlPlaneEndpoint`)으로 잡고 시작한다. 지금은 그 VIP를 chan08 혼자 들고 있다 — "VIP 하나에 백엔드 하나"인 셈이다. 나중에 컨트롤플레인 노드가 늘어나도([`05-llm-gpu-node.md`](05-llm-gpu-node.md) 참고) 주소 체계를 바꿀 필요가 없다는 게 핵심이다. 왜 이 순서가 중요한지는 아래 "알려진 이슈: 고정 IP로 시작하면 나중에 힘들다"에 정리해뒀다.

## 스크립트 목록 (이름 순)

### 커널/네트워크 전제조건
- 설명: Kubernetes가 요구하는 커널/네트워크 전제조건을 충족시킨다 (양쪽 노드).
- 스크립트: [`01-prereqs.sh`](../scripts/02-k8s-cluster/01-prereqs.sh)
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

### 컨테이너 런타임 설치
- 설명: 컨테이너 런타임을 설치한다 (양쪽 노드).
- 스크립트: [`02-containerd.sh`](../scripts/02-k8s-cluster/02-containerd.sh)
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

### kubeadm/kubelet/kubectl 설치
- 설명: kubeadm/kubelet/kubectl을 설치한다 (양쪽 노드, v1.36 기준).
- 스크립트: [`03-kube-packages.sh`](../scripts/02-k8s-cluster/03-kube-packages.sh)
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

### 컨트롤플레인 초기화
- 설명: 컨트롤플레인을 초기화한다 (chan08 전용). `--control-plane-endpoint`를 처음부터 VIP(10.5.5.3)로 지정한다 — 이 시점엔 VIP가 아직 실제로 떠 있지 않지만, kubeadm은 이 값을 인증서 SAN과 클러스터 설정에 기록만 할 뿐 실제로 그 주소에 접속을 시도하진 않는다. 대신 이후 자동 생성되는 kubeconfig(`~/.kube/config`)의 접속 주소가 이 VIP로 고정되므로, **다음 단계(VIP를 실제로 띄우는 것)를 하기 전까지는 kubectl이 응답하지 않는 게 정상이다.**
- 스크립트: [`04-init-control-plane.sh`](../scripts/02-k8s-cluster/04-init-control-plane.sh)
```bash
# 컨트롤플레인 초기화. 공유 진입점(VIP)과 파드 내부 IP 대역을 함께 지정
sudo kubeadm init \
  --apiserver-advertise-address=10.5.5.8 \
  --control-plane-endpoint=10.5.5.3:6443 \
  --upload-certs \
  --pod-network-cidr=10.244.0.0/16

# kubectl 설정 디렉터리 생성
mkdir -p ~/.kube

# 초기화 시 생성된 관리자 인증서를 일반 계정이 쓸 위치로 복사 (server 주소는 위 VIP로 자동 설정됨)
sudo cp -i /etc/kubernetes/admin.conf ~/.kube/config

# sudo 없이 kubectl을 쓸 수 있도록 소유자 변경 (설정 파일 + 디렉터리 모두)
sudo chown chan:chan ~/.kube/config ~/.kube
```
`--upload-certs`는 컨트롤플레인 인증서를 클러스터 안에(암호화해서) 미리 올려두는 옵션이다. 나중에 다른 노드를 컨트롤플레인으로 추가할 때, 그 인증서를 받아올 임시 열쇠(`--certificate-key`)를 매번 새로 발급받아 쓴다 — 이 열쇠는 2시간짜리라 지금 당장 안 쓰면 그냥 버려지고, 필요할 때 `kubeadm init phase upload-certs --upload-certs`로 다시 만들면 된다.

### API 서버 VIP keepalived 구성
- 설명: 앞 단계에서 만든 컨트롤플레인 앞에 keepalived VIP를 띄운다 (chan08 전용, 지금은 참여 노드가 1대뿐이라 무조건 MASTER). **반드시 컨트롤플레인 초기화 다음에 실행해야 한다** — 헬스체크가 이 노드의 로컬 apiserver(`127.0.0.1:6443/livez`)를 직접 확인하기 때문에, apiserver가 없는 상태에서 먼저 실행하면 VIP가 뜨자마자 몇 초 안에 다시 내려간다.
- 스크립트: [`05-setup-apiserver-vip-keepalived.sh`](../scripts/02-k8s-cluster/05-setup-apiserver-vip-keepalived.sh)
```bash
# keepalived 설치
sudo apt-get install -y keepalived

# 로컬 apiserver가 살아있는지 확인하는 헬스체크 스크립트
cat <<'EOF' | sudo tee /usr/local/bin/chk_k8s_apiserver.sh
#!/bin/bash
curl -sk --max-time 2 -o /dev/null -w '%{http_code}' https://127.0.0.1:6443/livez | grep -q 200
EOF
sudo chmod +x /usr/local/bin/chk_k8s_apiserver.sh

# keepalived.conf에 API 서버 전용 VRRP 인스턴스 추가 (virtual_router_id=52)
cat <<EOF | sudo tee -a /etc/keepalived/keepalived.conf

vrrp_script chk_k8s_apiserver {
    script "/usr/local/bin/chk_k8s_apiserver.sh"
    interval 2
    fall 3
    rise 2
}

vrrp_instance VI_K8S_APISERVER {
    state MASTER
    interface enp1s0
    virtual_router_id 52
    priority 150
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass <VRRP 인증암호>
    }
    virtual_ipaddress {
        10.5.5.3/24
    }
    track_script {
        chk_k8s_apiserver
    }
}
EOF

sudo systemctl restart keepalived
```
`<VRRP 인증암호>`는 `openssl rand -hex 4`(8자 제한) 등으로 한 번 생성해서 안전하게 기록해두고, 이 VIP에 나중에 합류할 모든 노드에 동일하게 써야 한다. `virtual_router_id`는 51(MySQL VIP, [`03-1-mysql-ha.md`](03-1-mysql-ha.md) 참고)과 겹치지 않게 52를 썼다 — 같은 keepalived.conf 안에 서로 다른 용도의 VRRP 인스턴스를 여러 개 둘 수 있다.

### 컨트롤플레인 마무리 (CNI + join 명령)
- 설명: VIP가 뜬 뒤에 CNI를 설치하고 워커 join 명령을 만든다 (chan08 전용). 이 단계부터는 kubectl이 VIP(10.5.5.3)를 통해 동작한다.
- 스크립트: [`06-finalize-control-plane.sh`](../scripts/02-k8s-cluster/06-finalize-control-plane.sh)
```bash
# Flannel CNI 설치 — 이 순간부터 서로 다른 노드의 파드끼리 통신 가능
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# 워커가 합류할 때 쓸 일회용 토큰과 join 명령 생성 (서버 주소는 VIP로 자동 채워짐)
kubeadm token create --print-join-command
```

### 워커 합류
- 설명: 워커를 클러스터에 합류시킨다 (chan09 전용). 컨트롤플레인 마무리 단계의 마지막 명령이 출력한 join 명령을 그대로 실행한다 (토큰과 해시는 실행할 때마다 새로 생성됨).
- 스크립트: [`07-join-worker.sh`](../scripts/02-k8s-cluster/07-join-worker.sh)
```bash
# chan08이 출력한 토큰/해시로 이 노드를 클러스터에 워커로 합류시킴 (주소가 VIP인 것에 주의)
sudo kubeadm join 10.5.5.3:6443 \
  --token <생성된 토큰> \
  --discovery-token-ca-cert-hash sha256:<해시>
```

### UFW FORWARD 정책 수정
- 설명: UFW FORWARD 정책을 수정한다 (아래 "알려진 이슈" 참고, 양쪽 노드).
- 스크립트: [`08-fix-ufw-forward.sh`](../scripts/02-k8s-cluster/08-fix-ufw-forward.sh)
```bash
# 서버를 그냥 거쳐가는(FORWARD) 트래픽까지 막던 기본 정책을 ACCEPT로 변경
sudo sed -i 's/^DEFAULT_FORWARD_POLICY="DROP"/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw

# 변경한 정책 즉시 반영
sudo ufw reload
```

### etcd 백업
- 설명: 컨트롤플레인이 chan08 하나뿐이라 etcd도 단일 장애점이다. 주기적으로 스냅샷을 떠서 최소한 복구는 가능하게 한다. 아래 "알려진 이슈"에 나오듯 etcd 컨테이너 이미지가 최소 구성이라 `kubectl cp`를 못 쓰고, hostPath 볼륨을 통해 호스트에서 직접 꺼낸다. (이 단일 장애점 자체는 이후 [`05-llm-gpu-node.md`](05-llm-gpu-node.md)에서 3노드 쿼럼으로 해소한다.)
- 스크립트: [`09-etcd-backup.sh`](../scripts/02-k8s-cluster/09-etcd-backup.sh)
```bash
# etcd 파드 안에서 스냅샷 생성 (hostPath 볼륨 /var/lib/etcd에 바로 씀)
kubectl -n kube-system exec etcd-chan08 -- etcdctl snapshot save /var/lib/etcd/etcd-backup-tmp.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key

# 스냅샷 무결성 확인
kubectl -n kube-system exec etcd-chan08 -- etcdutl snapshot status /var/lib/etcd/etcd-backup-tmp.db --write-out=table

# hostPath라 파드 안 경로와 호스트 경로가 같은 파일 - 호스트 쪽에서 바로 이동
sudo mv /var/lib/etcd/etcd-backup-tmp.db /data/etcd-backup/etcd-snapshot-<타임스탬프>.db
```
매일 새벽 자동 실행되도록 chan08의 crontab에 등록해뒀다 (KST 03:00, 최근 7개 보관, 로그는 스크립트와 같은 디렉토리):
```bash
0 3 * * * ~/k8s-cluster/09-etcd-backup.sh >> ~/k8s-cluster/etcd-backup.log 2>&1
```

## 알려진 이슈: 고정 IP로 시작하면 나중에 힘들다

컨트롤플레인을 `--control-plane-endpoint` 없이(즉 `--apiserver-advertise-address`만으로, 노드 하나의 고정 IP로) 초기화하면 당장은 아무 문제 없이 잘 동작한다. 문제는 **나중에 컨트롤플레인 노드를 추가하려 할 때** 터진다 — 이 프로젝트도 실제로 이 순서로 갔다가 겪었던 일이다.

- **`kubeadm join --control-plane`이 거부된다**: `unable to add a new control plane instance to a cluster that doesn't have a stable controlPlaneEndpoint address`. kubeadm은 "여러 컨트롤플레인이 공유하는 안정적인 주소"가 처음부터 선언돼 있어야만 추가 합류를 허용한다.
- **뒤늦게 VIP를 끼워 넣으려면 인증서까지 건드려야 한다**: 이미 발급된 apiserver 인증서의 SAN(Subject Alternative Name)에는 VIP가 없어서, `ClusterConfiguration`을 고쳐 controlPlaneEndpoint를 추가한 뒤 인증서를 강제로 재발급해야 한다. `kubeadm init phase certs apiserver`는 파일이 이미 있으면 재발급을 건너뛰므로 기존 파일을 지워야 하고, 떠 있는 apiserver 프로세스는 재시작해야 새 인증서를 읽는다(정적 파드 매니페스트를 잠깐 옮겼다 되돌리는 방식으로 강제).
- **join 명령 생성도 옛날 주소를 계속 가리킨다**: `kubeadm token create --print-join-command`가 참조하는 `kube-public/cluster-info` ConfigMap은 `ClusterConfiguration`과 별개로 저장돼 있어서, 위 재발급을 해도 자동으로 안 바뀐다. 이것까지 따로 고치지 않으면 새로 뽑은 join 명령이 여전히 옛날 고정 IP를 가리켜서 헷갈리는 실패를 겪는다.

이미 고정 IP로 초기화해버린 클러스터가 있다면 [`10-retrofit-control-plane-endpoint-from-fixed-ip.sh`](../scripts/02-k8s-cluster/10-retrofit-control-plane-endpoint-from-fixed-ip.sh)로 위 세 가지를 한 번에 처리할 수 있다 (기존 컨트롤플레인에서 1회 실행, `sudo ./10-retrofit-control-plane-endpoint-from-fixed-ip.sh <VIP>`). 하지만 애초에 이 문서처럼 [`04-init-control-plane.sh`](../scripts/02-k8s-cluster/04-init-control-plane.sh) 단계에서 VIP를 미리 정해두면 이 스크립트 자체가 필요 없다 — **컨트롤플레인을 하나만 쓸 계획이라도, 나중에 늘릴 가능성이 조금이라도 있다면 처음부터 VIP로 시작하는 쪽이 훨씬 싸게 먹힌다.**

내부적으로 하는 일(순서대로):
```bash
# 1) kube-system의 kubeadm-config ConfigMap에 controlPlaneEndpoint/certSAN 추가
kubectl -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' > /tmp/kubeadm-cluster-config.yaml
# (apiServer.certSANs에 VIP 추가 + controlPlaneEndpoint: <VIP>:6443 append 후)
kubectl -n kube-system create cm kubeadm-config \
  --from-file=ClusterConfiguration=/tmp/kubeadm-cluster-config.yaml \
  --dry-run=client -o yaml | kubectl apply -f -

# 2) apiserver 인증서를 새 SAN 포함해서 강제 재발급 (기존 파일이 있으면 kubeadm이 건너뛰므로 지워야 함)
rm /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.key
kubeadm init phase certs apiserver --config /tmp/kubeadm-cluster-config.yaml

# 3) apiserver 정적 파드 강제 재기동 (매니페스트를 잠깐 옮겼다 되돌리면 kubelet이 재기동시킴)
mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/kube-apiserver.yaml.tmp
sleep 5
mv /tmp/kube-apiserver.yaml.tmp /etc/kubernetes/manifests/kube-apiserver.yaml

# 4) admin.conf(사람용 kubeconfig)의 server 주소를 VIP로 변경
sed -i "s#https://<이 노드 IP>:6443#https://<VIP>:6443#" /etc/kubernetes/admin.conf
cp -f /etc/kubernetes/admin.conf ~/.kube/config

# 5) kube-public/cluster-info도 VIP로 갱신 (안 하면 join 명령이 계속 옛 고정 IP를 가리킴)
kubectl -n kube-public get cm cluster-info -o jsonpath='{.data.kubeconfig}' > /tmp/cluster-info-kubeconfig.yaml
sed -i "s#server: https://<이 노드 IP>:6443#server: https://<VIP>:6443#" /tmp/cluster-info-kubeconfig.yaml
kubectl -n kube-public create cm cluster-info \
  --from-file=kubeconfig=/tmp/cluster-info-kubeconfig.yaml \
  --dry-run=client -o yaml | kubectl apply -f -
```
실행 후 [`05-setup-apiserver-vip-keepalived.sh`](../scripts/02-k8s-cluster/05-setup-apiserver-vip-keepalived.sh)로 이어서 VIP를 실제로 띄우면 정상 절차(04→05→06)를 따라온 상태와 동일해진다.

## 알려진 이슈: UFW가 pod 네트워크를 막음

[`04-firewall.sh`](../scripts/01-provision/04-firewall.sh)로 UFW를 활성화하면 `/etc/default/ufw`의 `DEFAULT_FORWARD_POLICY`가 기본 `DROP`으로 설정된다. 이 상태에서는 iptables `FORWARD` 체인 기본 정책이 DROP이 되어, kube-proxy/Flannel이 만든 규칙에 명시적으로 걸리지 않는 pod→ClusterIP 트래픽이 막힌다. 실제로 CoreDNS가 `[WARNING] plugin/kubernetes: starting server with unsynced Kubernetes API` 상태에서 멈추는 증상으로 나타났다.

[`08-fix-ufw-forward.sh`](../scripts/02-k8s-cluster/08-fix-ufw-forward.sh)가 `DEFAULT_FORWARD_POLICY`를 `ACCEPT`로 바꾸고 `ufw reload`한다. **인바운드 규칙(10.5.5.0/24 제한)에는 영향 없음** — FORWARD 체인(라우팅되는 트래픽)만 대상. 앞으로 이 서버들에 UFW를 다시 초기화하는 경우 이 스크립트를 반드시 함께 적용해야 한다.

## 알려진 이슈: etcd 컨테이너 이미지엔 tar/cat/rm도 없음

etcd 스냅샷을 파드 밖으로 꺼내려고 `kubectl cp`를 쓰면 `tar: executable file not found`로 실패한다. etcd 공식 이미지가 etcdctl/etcdutl 정도만 들어있는 최소 구성이라 tar는 물론 cat, rm, which도 없다. `kubectl exec ... -- cat file > local` 같은 우회도 마찬가지로 안 된다.

해결: etcd 정적 파드의 매니페스트(`/etc/kubernetes/manifests/etcd.yaml`)를 보면 `/var/lib/etcd`가 hostPath 볼륨으로 그대로 마운트돼 있다. 스냅샷을 이 경로 밑에 저장하면 파드 안에서 쓴 파일이 호스트의 같은 경로에 그대로 나타나므로, `kubectl exec`로 파일을 꺼낼 필요 없이 호스트에서 바로 `sudo mv`/`sudo cp`하면 된다.

또한 `etcdctl`에는 3.6부터 `snapshot status`가 없다 — 스냅샷 무결성 확인은 오프라인 전용 도구인 `etcdutl`로 해야 한다(둘 다 이미지 안에 들어있음).

## 검증 명령

```bash
# 노드 상태 확인 (chan08, chan09 모두 Ready여야 함)
kubectl get nodes -o wide

# 시스템 파드 상태 확인 (kube-system, kube-flannel 전부 1/1 Running이어야 함)
kubectl get pods -A

# 클러스터 내부 DNS 테스트용 파드 실행
kubectl run dns-test --image=busybox:1.36 --restart=Never --command -- sleep 3600

# 테스트 파드에서 클러스터 내부 도메인 조회
kubectl exec dns-test -- nslookup kubernetes.default.svc.cluster.local

# 테스트 파드 정리
kubectl delete pod dns-test
```

kubeconfig는 chan08의 `~/.kube/config`에 있음 (작업 계정용, `kubectl`은 chan08에서 바로 사용 가능, 접속 주소는 VIP 10.5.5.3).

---

[← 이전: 서버 초기 프로비저닝](01-provision.md) · [다음: MySQL active/standby →](03-1-mysql-ha.md)
