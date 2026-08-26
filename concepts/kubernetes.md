# Kubernetes 개념 정리

Kubernetes를 처음부터 배우면서 이 클러스터를 만들었다. 새 컴포넌트를 추가할 때마다 그때 필요했던 개념을 여기에 추가한다 — 교과서적 정의보다 "우리 클러스터에서 실제로 이게 왜 필요했는지"를 우선한다.

## 파드별 역할과 배치 이유

같은 파드라도 "왜 그 노드에 떴는지"는 각자 다른 규칙 때문이다. 실제 설정값 기준으로, 각 항목마다 그걸 직접 조회하는 명령과 결과를 같이 둔다. 도메인/Ingress 이름은 실제 값 대신 `app1.example.com` 식으로 치환했다.

### 0. 노드
```bash
kubectl get nodes -o wide
```
```
NAME     STATUS   ROLES           AGE   VERSION   INTERNAL-IP
chan08   Ready    control-plane   2d8h  v1.36.4   10.5.5.8
chan09   Ready    control-plane   2d8h  v1.36.4   10.5.5.9
llm001   Ready    control-plane   8h    v1.36.4   10.5.5.10
```
세 노드 다 `control-plane` 롤을 달고 있다. 물리 노드가 정확히 3대뿐이라 "컨트롤플레인 전용 노드"를 따로 뺄 여유가 없어서, 전부 컨트롤플레인 겸 워커로 쓰는 구성이다(kubeadm의 stacked etcd 토폴로지). llm001에는 `nvidia.com/gpu=true` 라벨이 추가로 붙어있다 — GPU를 가진 노드라는 표시.

**nginx/인증서(Stage 5) 작업 전, 완전 깡통 상태의 기본 데몬**은 아래 항목 중 1~2번뿐이었다 — `kubeadm init` + Flannel(CNI) 설치만으로 나오는 최소 구성:
- kube-system: etcd, kube-apiserver, kube-controller-manager, kube-scheduler (정적 파드)
- kube-system: kube-proxy (DaemonSet)
- kube-system: coredns (Deployment)
- kube-flannel: kube-flannel-ds (DaemonSet) — CNI는 kubeadm이 자동으로 깔아주지 않고 따로 설치해야 하지만, 파드 네트워크가 동작하려면 반드시 있어야 해서 사실상 베이스라인에 포함된다.

3번(metallb-system), 4번의 ingress-nginx, 5번(cert-manager, cm-acme-http-solver)은 Stage 5에서, 6번(nvidia-device-plugin)은 Stage 6(GPU 노드 추가, [`06-llm-gpu-node.md`](../lessons/06-llm-gpu-node.md))에서 나중에 얹은 것들이다.

### 1. 정적 파드 — etcd, kube-apiserver, kube-controller-manager, kube-scheduler (3대 전부)
```bash
kubectl -n kube-system get pods -l tier=control-plane -o wide
```
```
NAME                             READY   STATUS    NODE
etcd-chan08                      1/1     Running   chan08
etcd-chan09                      1/1     Running   chan09
etcd-llm001                      1/1     Running   llm001
kube-apiserver-chan08            1/1     Running   chan08
kube-apiserver-chan09            1/1     Running   chan09
kube-apiserver-llm001            1/1     Running   llm001
kube-controller-manager-chan08   1/1     Running   chan08
kube-controller-manager-chan09   1/1     Running   chan09
kube-controller-manager-llm001   1/1     Running   llm001
kube-scheduler-chan08            1/1     Running   chan08
kube-scheduler-chan09            1/1     Running   chan09
kube-scheduler-llm001            1/1     Running   llm001
```
- 역할: 클러스터의 두뇌. etcd는 상태 저장소, kube-apiserver는 모든 요청이 거치는 관문, controller-manager/scheduler는 각각 리소스 상태 맞추기와 파드 배치를 담당한다.
- 왜 3대 전부: 스케줄러가 배치한 일반 파드가 아니라 "정적 파드"다. kubelet이 `/etc/kubernetes/manifests/`에 있는 파일을 그 노드에서만 직접 읽어서 띄우는 방식이라, 컨트롤플레인으로 join된 노드마다 각자 이 파일들을 갖고 있다. 처음엔 chan08 하나뿐이었다가, chan09/llm001을 `kubeadm join --control-plane`으로 추가해서 지금은 3대 모두에 있다.
- 관련 설정: `hostNetwork: true`라서 파드 전용 IP(10.244.x) 없이 노드 IP를 그대로 쓴다.

### 컨트롤플레인 HA — etcd 쿼럼과 API 서버 VIP
```bash
kubectl -n kube-system exec etcd-chan08 -- etcdctl member list \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
  --write-out=table
```
```
+------------------+---------+--------+------------------------+------------------------+
|        ID        | STATUS  |  NAME  |       PEER ADDRS       |      CLIENT ADDRS      |
+------------------+---------+--------+------------------------+------------------------+
| 5ad480bb8fe14802 | started | chan09 |  https://10.5.5.9:2380 |  https://10.5.5.9:2379 |
| 674ecf81a092285e | started | chan08 |  https://10.5.5.8:2380 |  https://10.5.5.8:2379 |
| f505e1368929ce05 | started | llm001 | https://10.5.5.10:2380 | https://10.5.5.10:2379 |
+------------------+---------+--------+------------------------+------------------------+
```
- **처음엔 chan08 하나뿐이라 진짜 장애 지점(SPOF)이었다.** etcd가 chan08에만 있어서 chan08이 죽으면 클러스터 상태 전체를 잃을 위험이 있었고, API 서버가 없으니 kubectl도, 새 파드 스케줄링도, 이미 떠 있는 파드의 재시작 판단도 전부 멈추는 상태였다(떠 있던 파드 자체는 당분간 계속 돔).
- **노드를 1대만 추가해서는 안 고쳐진다.** etcd는 과반수(quorum) 투표로 동작해서 절대 짝수로 두면 안 된다 — 컨트롤플레인 2대면 하나가 죽었을 때 남은 1대가 "과반"이 안 돼서(2대 중 1대는 정확히 절반이지 과반이 아님) 여전히 아무것도 못 하고, 오히려 네트워크가 잠깐 끊기기만 해도 스플릿 브레인 위험만 늘어난다.
- **물리 노드가 3대가 되면서 실제로 고쳤다.** chan09, llm001을 순서대로 `kubeadm join --control-plane`으로 합류시켜서 etcd 멤버 3개(홀수)를 만들었다 — 이제 아무 노드 1대가 죽어도 나머지 2대가 과반이라 클러스터가 계속 동작한다.
- **API 서버 접속용 VIP도 별도로 필요하다.** etcd/apiserver가 3대에 분산돼도, kubectl이나 각 노드의 kubelet이 여전히 chan08 IP 하나만 보고 있으면 chan08이 죽었을 때 여전히 접속할 곳이 없다. keepalived로 VIP(10.5.5.3)를 3대가 우선순위 기반으로 나눠 갖게 하고, `admin.conf`(kubectl 설정)가 이 VIP를 보게 만들었다 — VIP를 든 노드는 자기 자신의 apiserver가 그대로 응답하므로 별도 로드밸런서가 없어도 된다.
- **kubelet/controller-manager/scheduler의 kubeconfig는 VIP가 아니라 각자 자기 자신의 IP를 본다** — kubeadm이 컨트롤플레인 노드마다 그렇게 자동 생성해준다. 로컬 apiserver가 제일 빠르고, 그 노드가 살아있으면 로컬 apiserver도 살아있다고 보기 때문에 의도된 동작이다. 그래서 이 공유 진입점은 사실상 `admin.conf`(사람이 쓰는 kubectl 접속)용으로만 쓰인다. 자세한 절차는 [`06-llm-gpu-node.md`](../lessons/06-llm-gpu-node.md) 참고.
- **왜 VIP(keepalived)고 DNS 라운드로빈/페일오버는 아닌지.** 도메인 하나에 여러 IP를 걸어두는 방식(멀티 데이터센터처럼 VRRP가 아예 안 되는 환경에서 흔히 씀)도 기능적으로는 가능하다. 하지만 DNS는 "누가 살아있는지" 자체를 모른다 — 죽은 IP로 접속을 실제로 시도해서 실패한 뒤에야 재시도하고, TTL을 아무리 낮춰도 헬스체크와 레코드 갱신을 능동적으로 해주는 별도 장치(Route53 헬스체크 같은) 없이는 그마저도 안 되며, 캐시 전파 시간만큼 항상 VIP보다 느리다. VRRP(keepalived)는 같은 서브넷(L2)에 있어야 한다는 제약이 있는 대신, 캐시 계층 없이 초 단위로 즉시 넘어간다. 우리는 3대가 전부 같은 서브넷(10.5.5.0/24)이라 VRRP 제약에 안 걸리므로 VIP 쪽을 택했다 — 노드가 서로 다른 네트워크(멀티 사이트)에 흩어지는 상황이 오면 그때는 DNS 기반 페일오버로 갈아타야 한다.

### API 서버를 꼭 거쳐야 하나 — 우회 경로
kubectl, kube-scheduler, kube-controller-manager, kubelet의 상태 보고는 전부 API 서버를 거친다. **etcd에 직접 쓰는 컴포넌트는 API 서버 하나뿐**이다 — 인증/권한(RBAC), 유효성 검사(admission control), 감사 로그, watch 알림이 전부 API 서버 한 곳에 모여야 일관성이 보장되기 때문. 하지만 긴급 상황에서 API 서버를 우회하는 진짜 콘솔 레벨 경로도 있고, 이 저장소를 다루면서 실제로 다 써봤다:
- **정적 파드 매니페스트 직접 조작**: `/etc/kubernetes/manifests/*.yaml`을 옮겼다 되돌리면 kubelet이 그 노드 로컬 파일을 직접 읽어서 파드를 재기동한다 (API 서버는 관여 안 함). chan08 apiserver 인증서를 갱신한 뒤 이 방법으로 재기동시켰다 — 애초에 이 방식이 없으면 "apiserver를 띄우려면 apiserver가 필요하다"는 모순이 생긴다.
- **etcd에 직접 질의**: `etcdctl snapshot save`, `etcdctl member list`를 API 서버가 아니라 etcd(`--endpoints=https://127.0.0.1:2379`)에 바로 물었다. API 서버가 완전히 죽어도 이 명령들은 그대로 동작한다.
- **컨테이너 런타임 직접 조회**: `ctr -n k8s.io containers ls`처럼 containerd에 바로 물어보면 kubelet/API 서버 없이도 그 노드에 뭐가 떠 있는지 확인 가능.
- **kubeadm reset/join**: 근본적으로 그 노드의 로컬 파일(`/etc/kubernetes/`, `/var/lib/kubelet/`)을 직접 조작하는 호스트 작업이다.

컨트롤플레인 전체가 죽어서 API 서버가 하나도 안 뜨는 최악의 상황이면: 이미 떠 있던 애플리케이션 파드는 kubelet이 로컬 캐시로 계속 관리해서 안 사라지고(새 스케줄링만 멈춤), 복구는 API 서버 없이도 되는 etcd 스냅샷(`07-etcd-backup.sh`)으로 한다.

### 2. DaemonSet — kube-flannel, kube-proxy, metallb-system/speaker (전부 노드마다 하나씩)
```bash
kubectl -n kube-flannel get pods -o wide
```
```
NAME                    READY   STATUS    NODE
kube-flannel-ds-xrv7b   1/1     Running   chan08
kube-flannel-ds-z97ts   1/1     Running   chan09
kube-flannel-ds-cl2bw   1/1     Running   llm001
```
```bash
kubectl -n kube-system get pods -l k8s-app=kube-proxy -o wide
```
```
NAME               READY   STATUS    NODE
kube-proxy-55bwl   1/1     Running   chan09
kube-proxy-924dx   1/1     Running   chan08
kube-proxy-wszxn   1/1     Running   llm001
```
```bash
kubectl -n metallb-system get pods -l component=speaker -o wide
```
```
NAME            READY   STATUS    NODE
speaker-8s7z7   1/1     Running   chan09
speaker-tww5r   1/1     Running   chan08
speaker-vxgk8   1/1     Running   llm001
```
- 대분류가 같다: DaemonSet은 "노드가 몇 개든 그 수만큼" 뜨는 게 기본 동작이라 셋 다 원칙적으로 모든 노드에 하나씩 있다. 노드가 2대에서 3대(llm001 추가)로 늘어나자 별다른 설정 변경 없이 자동으로 세 번째 파드가 llm001에도 생겼다.
- 각자 역할: flannel은 파드 네트워크(오버레이) 제공, kube-proxy는 Service 라우팅 규칙(iptables)을 그 노드에 실제로 심어주는 주체, speaker는 VIP에 대한 ARP 응답과 리더 선출.
- 지금은 노드에 taint가 하나도 없어서(아래 "스케줄링 제어" 참고) 이 셋 다 toleration 유무와 무관하게 뜬다. 예전엔 control-plane taint가 있는 노드에도 뜨도록 각자 다른 방식으로 toleration을 갖고 있었다 — flannel은 `{"effect":"NoSchedule","operator":"Exists"}`(key 없는 와일드카드), speaker는 control-plane/master taint를 콕 집어 참는 toleration, kube-proxy는 kubeadm이 애초에 그렇게 배포. taint가 사라진 지금도 이 toleration들은 그대로 남아있는데(무해함), 나중에 다시 taint가 생겨도 자동으로 버틴다.
- speaker만 `hostNetwork: true`가 추가로 붙는다 — VIP의 ARP 응답은 파드 네트워크가 아니라 노드의 실제 네트워크 인터페이스에서 처리해야 하기 때문.

### 2-1. GPU 전용 DaemonSet — nvidia-device-plugin (llm001에만, nodeSelector로 제한)
```bash
kubectl -n kube-system get pods -l name=nvidia-device-plugin-ds -o wide
```
```
NAME                                   READY   STATUS    NODE
nvidia-device-plugin-daemonset-6plgc   1/1     Running   llm001
```
- 위 셋과 같은 DaemonSet이지만 `nodeSelector: nvidia.com/gpu: "true"`가 걸려있어서 그 라벨이 붙은 노드(llm001)에만 뜬다 — "모든 노드에 하나씩"이 기본값인 DaemonSet도 nodeSelector로 범위를 좁힐 수 있다.
- 역할: 노드가 가진 GPU를 `nvidia.com/gpu`라는 이름의 스케줄링 가능한 리소스로 kube-apiserver에 등록해준다. 이게 있어야 파드가 `resources.limits: {nvidia.com/gpu: 1}`로 GPU를 요청할 수 있다.
- GPU 전용 taint는 걸지 않았다 — `nvidia.com/gpu` 리소스를 실제로 가진 노드가 llm001뿐이라서, GPU를 요청하는 파드는 taint 없이도 스케줄러가 자동으로 거기로만 보낸다. taint를 걸면 오히려 llm001에 일반 워크로드가 못 올라가는 손해만 있어서 뺐다.

### 3. Deployment, toleration 없음 — metallb-system/controller, cert-manager 3종 (지금은 chan09에 있음)
```bash
kubectl -n metallb-system get pods -l component=controller -o wide
```
```
NAME                         READY   STATUS    NODE
controller-658745d67-cnnhr   1/1     Running   chan09
```
```bash
kubectl -n cert-manager get pods -o wide
```
```
NAME                                       READY   STATUS    NODE
cert-manager-69c7fcbf78-qdvfl              1/1     Running   chan09
cert-manager-cainjector-69f8c8cdbf-qtrc9   1/1     Running   chan09
cert-manager-webhook-84fd89df64-frkch      1/1     Running   chan09
```
- 역할: controller는 어느 노드가 VIP를 받을지 조정하는 두뇌(실제 트래픽 처리는 speaker가 함), cert-manager 3종은 인증서 발급/갱신 처리.
- 왜 지금 chan09에: 이 파드들엔 toleration이 아예 없다. **예전엔** control-plane taint가 있는 chan08엔 못 뜨고 워커인 chan09만 후보라 자동으로 거기로 갔던 것인데, 지금은 3대 다 taint가 없어서 이 파드들도 chan08이나 llm001에 뜰 수 있다 — 다만 **k8s는 이미 떠서 잘 돌고 있는 파드를 taint 상황이 바뀌었다고 알아서 다른 노드로 옮기지 않는다.** 스케줄링은 파드가 "새로 생성되는 시점"에만 일어나기 때문에, 지금 chan09에 있는 건 예전에 그렇게 배치된 게 그대로 남아있는 것뿐이다. 파드를 지웠다 다시 만들면 그때는 3대 중 아무 데나 갈 수 있다.

### 4. Deployment + anti-affinity로 노드 분산 — coredns, ingress-nginx-controller (노드당 1개씩 강제, replicas=2라 3대 중 2대에만)
```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
```
```
NAME                      READY   STATUS    NODE
coredns-bbf8c64b6-fvqtp   1/1     Running   chan09
coredns-bbf8c64b6-st5qd   1/1     Running   chan08
```
```bash
kubectl -n ingress-nginx get pods -l app.kubernetes.io/component=controller -o wide
```
```
NAME                                       READY   STATUS    NODE
ingress-nginx-controller-ccfdd7f8c-5wqth   1/1     Running   chan09
ingress-nginx-controller-ccfdd7f8c-tqpmb   1/1     Running   chan08
```
- 둘 다 "같은 라벨의 파드는 서로 다른 노드에"를 `requiredDuringSchedulingIgnoredDuringExecution`(강제)로 걸어놔서 항상 노드당 1개씩 유지된다. `replicas: 2`라 지금은 3대 중 2대(chan08, chan09)에만 있고 llm001은 비어있다 — anti-affinity는 "같은 노드에 몰리지 마라"는 규칙이지 "모든 노드에 하나씩 채워라"가 아니라서, replicas를 3으로 올리지 않는 한 세 번째 노드는 그냥 후보에서 빠진다.
- coredns는 원래 기본값이 `preferredDuringScheduling`(권장, 강제 아님)이라 처음엔 우연히 둘 다 chan09에 몰려있었다 — chan09가 죽으면 클러스터 DNS가 통째로 끊기는 상태였다. `kubectl patch`로 `required`로 바꾸고 파드 하나를 지워서 강제로 재배치시켜 해결했다 (Deployment의 파드 템플릿을 바꿔도 이미 떠 있는 파드는 스스로 안 움직이므로, 최소 하나는 삭제해서 다시 뜨게 해야 새 규칙이 적용된다).
- ingress-nginx-controller는 [`05-ingress.md`](../lessons/05-ingress.md)에서 처음부터 `required`로 만들었다.

### 5. 임시 파드 — cm-acme-http-solver-*
```bash
kubectl get pods -A | grep acme-http-solver
```
```
default   cm-acme-http-solver-bprjq   1/1   Running   0   7h49m
default   cm-acme-http-solver-n8q7x   1/1   Running   0   7h49m
```
- 역할: cert-manager가 인증서 발급 순간에만 잠깐 만드는 ACME HTTP-01 챌린지 응답용 파드. 발급이 끝나면 자동으로 사라진다.

## 기본 단위

### 클러스터 / 노드
클러스터는 여러 대의 서버를 묶어서 하나처럼 쓰는 단위다. 그 서버 한 대 한 대를 노드라고 부른다. 처음엔 chan08(컨트롤플레인) + chan09(워커) 2대였고, 지금은 GPU 머신(llm001)까지 합류해서 3대 다 컨트롤플레인 겸 워커로 구성돼 있다.

- **컨트롤플레인**: 클러스터 전체를 관리하는 두뇌 역할. API 서버(kubectl이 말 거는 대상), 스케줄러(어느 노드에 뭘 띄울지 결정), etcd(클러스터 상태 저장소) 같은 게 여기서 돈다.
- **워커**: 실제 애플리케이션(파드)이 도는 노드. 컨트롤플레인도 기본적으로 워커 역할을 겸할 수 있는데, kubeadm 기본값은 "컨트롤플레인엔 일반 파드를 안 올린다"는 정책(Taint)을 걸어둔다 — 우리는 노드가 3대뿐이라 이 taint를 셋 다 없애고 완전히 대칭으로 쓴다 (아래 "스케줄링 제어" 참고).

### 파드(Pod)
Kubernetes가 다루는 가장 작은 배포 단위. 컨테이너 하나(또는 몇 개)를 감싼 것이라고 보면 된다. 파드는 언제든 죽었다 다시 만들어질 수 있고, 그때마다 IP가 바뀐다 — 그래서 파드 IP를 직접 기억해서 접속하면 안 되고, 아래 Service를 거쳐야 한다.

### 디플로이먼트(Deployment) / 데몬셋(DaemonSet)
파드를 직접 만들지 않고, "이런 파드를 N개 유지해줘"라고 선언하는 상위 리소스.
- **Deployment**: 지정한 개수(`replicas`)만큼 파드를 유지. 예: ingress-nginx를 `replicas: 2`로 설정해서 chan08·chan09에 하나씩 뜨게 함.
- **DaemonSet**: "모든 노드에 하나씩" 뜨는 특수한 형태. 예: MetalLB의 speaker, kube-proxy가 이 방식.

### 네임스페이스(Namespace)
같은 클러스터 안에서 리소스를 논리적으로 구분하는 "구역" 개념. `metallb-system`, `ingress-nginx`, `cert-manager`처럼 컴포넌트별로 네임스페이스를 나눠서 설치한다. 같은 이름의 리소스도 네임스페이스가 다르면 완전히 별개로 존재한다.

- **실전에서 제일 자주 걸리는 함정**: `kubectl get pods`만 치면 `default` 네임스페이스만 보여준다. 우리가 설치한 인프라 컴포넌트는 거의 다 `default`가 아니라 각자 전용 네임스페이스에 있어서 아무것도 안 보인다 — 그래서 이 문서 전체에서 `-n metallb-system`처럼 네임스페이스를 지정하거나, 전체를 다 보는 `-A`(all namespaces)를 계속 붙인다.
- **모든 리소스가 네임스페이스에 속하지는 않는다.** Pod, Deployment, Service, ConfigMap, Secret 등은 네임스페이스에 속하지만(namespaced), Node, PersistentVolume, ClusterRole, ClusterIssuer, Namespace 자체 같은 건 클러스터 전체 단위라 네임스페이스가 없다(cluster-scoped) — `kubectl get node`에 `-n`이 안 먹히는 이유다.
- **다른 네임스페이스의 Service는 이름만으론 못 부른다.** 같은 네임스페이스 안에서는 서비스 이름만 써도 되지만, 다른 네임스페이스의 Service를 부르려면 `서비스이름.네임스페이스.svc.cluster.local`처럼 네임스페이스를 붙여야 CoreDNS가 찾아준다.
- **Namespace와 Label은 다르다.** Namespace는 리소스가 "어디 소속"인지 정하는 딱딱한 경계(리소스 하나는 정확히 하나에만 속함)고, Label은 그냥 붙이는 태그(하나에 여러 개 가능, 격리 경계가 아니라 검색/필터링용)다. 이 문서에서 파드 배치 이유를 조회할 때 `kubectl -n kube-system get pods -l tier=control-plane`처럼 **네임스페이스로 먼저 구역을 좁히고, 그 안에서 라벨로 더 세밀하게 필터링**하는 조합을 계속 쓰는 이유다.

## 네트워킹

### Service — 파드 앞에 붙는 고정 주소
파드는 죽으면 IP가 바뀌니, 그 앞에 "고정된 주소 하나"를 만들어주는 게 Service다. 뒤에 파드가 몇 개든, 어떤 파드가 죽고 새로 뜨든 Service의 주소는 안 바뀐다. 세 종류를 다 써봤다.
- **ClusterIP**: 클러스터 내부에서만 보이는 주소. 기본값. 예: `kubernetes` Service(API 서버), `kube-dns`(CoreDNS).
- **NodePort**: 각 노드의 특정 포트(30000-32767)로 클러스터 밖에서도 접근 가능하게 열어줌.
- **LoadBalancer**: 클라우드에서는 외부 로드밸런서를 자동으로 발급받는 타입인데, 베어메탈엔 그런 게 없어서 MetalLB가 이 역할을 대신 채워준다 (아래 참고).

### hostNetwork — 파드 전용 IP 없이 호스트 IP를 그대로 씀
보통 파드는 자기만의 네트워크 네임스페이스를 받아서 CNI(Flannel)가 만든 가상 인터페이스로 파드 전용 대역(`10.244.x.x`)의 IP를 받는다 — 호스트의 실제 네트워크 스택과는 분리돼 있다. `hostNetwork: true`를 주면 이 격리를 아예 안 하고 **호스트의 네트워크 네임스페이스를 그대로 공유**한다. 컨테이너가 포트를 열면 가상 IP나 NAT 없이 그 노드의 실제 IP에 바로 열린다 (`kubectl get pod -o wide`의 IP 칸에도 `10.244.x.x`가 아니라 노드 IP가 그대로 찍힌다).
- `etcd-chan08`, `kube-apiserver-chan08` 등 정적 파드가 이 방식이라, apiserver가 `10.5.5.8:6443`처럼 노드 IP에 직접 떠 있다 — 클러스터 부트스트랩 단계엔 아직 파드 네트워크 자체가 없어서, 애초에 hostNetwork가 아니면 다른 노드가 접속할 방법이 없다.
- `speaker`(MetalLB)도 이 방식이다 — VIP에 대한 ARP 응답은 노드의 실제 네트워크 인터페이스에서 처리해야 하는 일이라 가상 파드 네트워크 안에서는 할 수 없다.
- **`ingress-nginx-controller`는 hostNetwork를 안 쓴다.** 일반 파드처럼 `10.244.x.x` 대역의 파드 전용 IP를 받고, 외부 트래픽은 아래 Service(LoadBalancer)와 MetalLB가 만든 VIP를 거쳐 kube-proxy가 그 파드 IP로 라우팅해주는 완전히 다른 경로를 탄다.
- 부작용: 네트워크 네임스페이스를 공유하므로, 같은 노드에 hostNetwork 파드 두 개가 같은 포트를 쓰려 하면 일반 프로세스끼리 포트 충돌 나는 것과 똑같이 충돌난다.

### kube-proxy — Service를 실제로 동작시키는 주체
Service는 그 자체로는 "규칙 선언"일 뿐이고, 그 규칙을 노드의 iptables 규칙으로 실제 변환해서 트래픽을 파드로 보내주는 게 kube-proxy다. 모든 노드에서 DaemonSet으로 돈다. 어느 노드로 패킷이 들어오든, 그 노드의 kube-proxy가 Service 뒤의 파드 중 하나로 분산(로드밸런싱)해준다 — 파드가 다른 노드에 있어도 상관없다(Flannel 오버레이로 넘어감).

### CoreDNS — 클러스터 내부 이름 해석
파드나 Service를 이름(`kube-dns.kube-system.svc.cluster.local` 같은)으로 찾을 수 있게 해주는 클러스터 내부 DNS 서버. `kube-system` 네임스페이스에 파드로 떠 있다. 예를 들어 파드 안에서 `kubectl.default.svc.cluster.local`처럼 이름으로 접속하면 CoreDNS가 실제 ClusterIP로 바꿔준다.

### EndpointSlice — Service가 실제로 가리키는 대상 목록
Service의 "뒷단 실체" 목록. 보통은 자동으로 만들어지지만(Service의 selector에 맞는 파드들), 클러스터 밖에 있는 서버로 트래픽을 보내고 싶을 때는 selector 없는 Service를 만들고 EndpointSlice를 손으로 등록해서 "이 Service는 저 바깥 IP:포트를 가리켜라"라고 지정할 수 있다. (예전엔 `Endpoints`라는 리소스를 썼는데 v1.33부터 deprecated, `EndpointSlice`가 표준.)

### Ingress / IngressClass — 도메인 기반 라우팅
Service가 "하나의 고정 주소"라면, Ingress는 그 앞에서 "어떤 도메인/경로로 오면 어떤 Service로 보낼지"를 정하는 규칙이다. HTTP(S) 전용. 예: `chat.example.com`이면 A Service로, `stock.example.com`이면 B Service로. 이 규칙을 실제로 처리하는 프로그램(우리는 ingress-nginx)이 필요하고, 클러스터에 여러 종류의 Ingress 컨트롤러가 있을 수 있어서 어떤 컨트롤러를 쓸지 `ingressClassName`으로 지정한다(우리는 `nginx`).

### MetalLB — 베어메탈에서 LoadBalancer를 만드는 도구
클라우드가 아니라서 "LoadBalancer 타입 Service를 만들면 외부 IP가 자동으로 나온다"는 게 원래는 안 된다. MetalLB가 이 역할을 대신한다 — 지정해둔 IP 대역(IPAddressPool) 중 하나를 Service에 할당해주고, L2 모드에서는 그 IP에 대한 ARP 응답을 노드 중 하나가 맡아서(리더) 처리한다. 리더가 죽으면 다른 노드가 자동으로 넘겨받는다. 진짜 "여러 노드가 동시에 패킷을 받는" BGP 모드도 있지만 홈 라우터로는 못 쓴다.

## 인증서

### cert-manager / ACME / ClusterIssuer / Certificate
- **ACME**: Let's Encrypt 같은 곳에서 인증서를 자동으로 발급받는 프로토콜 이름.
- **cert-manager**: 이 ACME 절차를 Kubernetes 리소스로 자동화해주는 컨트롤러.
- **ClusterIssuer**: "어느 CA(발급기관)에, 어떤 방식으로 인증서를 요청할지"를 등록해두는 설정. 우리는 Let's Encrypt staging/production 둘을 등록해뒀다.
- **Certificate**: "이 도메인의 인증서를 발급받아서 이 이름의 Secret에 넣어줘"라는 요청. Ingress에 `cert-manager.io/cluster-issuer` annotation을 붙이면 cert-manager가 이 Certificate를 자동으로 만들어준다.
- 발급 과정에서 내부적으로 `Order`(발급 요청 전체)와 `Challenge`(도메인 소유 증명 절차 — 우리는 HTTP-01, 즉 `/.well-known/acme-challenge/...` 경로 응답으로 증명하는 방식)라는 리소스가 잠깐 생겼다 사라진다.

## 스케줄링 제어

### Taint / Toleration — "이 노드엔 함부로 못 올라옴"
Taint는 노드에 붙이는 "거부 딱지"다. `키=값:효과` 형태이고, 파드가 "나는 이 딱지 무시하고 뜰 수 있어"라고 선언하는 게 Toleration이다. 효과는 세 가지: `NoSchedule`(새 배치만 막음), `PreferNoSchedule`(가능하면 피함, 강제 아님), `NoExecute`(새 배치도 막고 이미 떠 있는 파드도 쫓아냄).

**taint/toleration은 "막기"만 하지 "끌어오기"는 못 한다.** toleration이 있다고 그 노드로 가는 게 아니라, 그냥 "거기도 갈 수 있는 후보"가 될 뿐이다. 특정 노드에 반드시 고정하려면 별도로 nodeSelector/nodeAffinity를 같이 써야 한다 — nvidia-device-plugin이 `nodeSelector: nvidia.com/gpu: "true"`로 GPU 노드에 고정되는 게 그 예.

kubeadm은 컨트롤플레인 노드에 기본적으로 `node-role.kubernetes.io/control-plane:NoSchedule` taint를 건다(일반 파드가 못 올라오게). 우리도 처음엔 이걸 그대로 뒀다가, GPU 노드(llm001)에도 `nvidia.com/gpu=present:NoSchedule` taint를 걸어봤는데 — 노드가 3대뿐인 상황에서 컨트롤플레인 taint가 3대 전부에 붙어버리자 toleration 없는 일반 워크로드(cert-manager 등)가 클러스터 어디에도 못 뜨는 문제가 생겼다. 게다가 GPU taint는 애초에 불필요했다 — GPU 요청 파드는 `nvidia.com/gpu` 리소스를 가진 노드가 거기뿐이라 taint 없이도 자동으로 거기로만 갔기 때문. 결국 지금은 3대 다 taint를 없애고 완전 대칭으로 운영한다(자세한 경위는 [`06-llm-gpu-node.md`](../lessons/06-llm-gpu-node.md) 참고).

### Affinity / Anti-affinity — "같이 뜨게" 또는 "따로 뜨게"
파드를 어디에 스케줄할지에 대한 세밀한 규칙. Anti-affinity로 "같은 라벨을 가진 파드는 서로 다른 노드에 하나씩만" 강제해서, ingress-nginx 파드 2개가 각각 다른 노드에 뜨도록 만들었다(둘 다 chan09에 몰리는 걸 방지).
