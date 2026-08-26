# Kubernetes 개념 정리

Kubernetes를 처음부터 배우면서 이 클러스터를 만들었다. 새 컴포넌트를 추가할 때마다 그때 필요했던 개념을 여기에 추가한다 — 교과서적 정의보다 "우리 클러스터에서 실제로 이게 왜 필요했는지"를 우선한다.

## 현재 클러스터 현황

2026-08-26 기준 실제 상태. 아래 개념 설명에서 나오는 것들이 실제로 클러스터에 어떻게 떠 있는지 대조해서 보면 된다. 도메인/Ingress 이름은 실제 값 대신 `app1.example.com` 식으로 치환했다.

```
=== 노드 ===
NAME     STATUS   ROLES           AGE   VERSION   INTERNAL-IP
chan08   Ready    control-plane   38h   v1.36.4   10.5.5.8
chan09   Ready    <none>          38h   v1.36.4   10.5.5.9

=== 네임스페이스별 파드 ===
NAMESPACE        NAME                                       READY   STATUS    NODE
cert-manager     cert-manager-69c7fcbf78-hmn2x              1/1     Running   chan09
cert-manager     cert-manager-cainjector-69f8c8cdbf-tsshv   1/1     Running   chan09
cert-manager     cert-manager-webhook-84fd89df64-tf67f      1/1     Running   chan09
ingress-nginx    ingress-nginx-controller-ccfdd7f8c-cldwc   1/1     Running   chan09
ingress-nginx    ingress-nginx-controller-ccfdd7f8c-tqpmb   1/1     Running   chan08
kube-flannel     kube-flannel-ds-xrv7b                      1/1     Running   chan08
kube-flannel     kube-flannel-ds-z97ts                      1/1     Running   chan09
kube-system      coredns-589f44dc88-2gsg4                   1/1     Running   chan09
kube-system      coredns-589f44dc88-q49tq                   1/1     Running   chan09
kube-system      etcd-chan08                                1/1     Running   chan08
kube-system      kube-apiserver-chan08                      1/1     Running   chan08
kube-system      kube-controller-manager-chan08              1/1     Running   chan08
kube-system      kube-proxy-55bwl                            1/1     Running   chan09
kube-system      kube-proxy-924dx                            1/1     Running   chan08
kube-system      kube-scheduler-chan08                       1/1     Running   chan08
metallb-system   controller-658745d67-49z4m                  1/1     Running   chan09
metallb-system   speaker-8s7z7                                1/1     Running   chan09
metallb-system   speaker-tww5r                                1/1     Running   chan08

=== 서비스 (일부) ===
NAMESPACE        NAME                        TYPE           CLUSTER-IP    EXTERNAL-IP   PORT(S)
ingress-nginx    ingress-nginx-controller    LoadBalancer   10.96.95.194  10.5.5.2      80:31421/TCP,443:30615/TCP
kube-system      kube-dns                    ClusterIP      10.96.0.10    <none>        53/UDP,53/TCP,9153/TCP
default          ext-app1-example-com        ClusterIP      10.104.34.159 <none>        4200/TCP
default          ext-app2-example-com        ClusterIP      10.107.17.142 <none>        4200/TCP
default          ext-app3-example-com        ClusterIP      10.99.85.239  <none>        80/TCP
default          ext-app4-example-com        ClusterIP      10.109.212.113 <none>       13000/TCP

=== Ingress ===
NAMESPACE   NAME                CLASS   HOSTS               ADDRESS             PORTS
default     app1-example-com    nginx   app1.example.com    10.5.5.8,10.5.5.9   80, 443
default     app2-example-com    nginx   app2.example.com    10.5.5.8,10.5.5.9   80, 443
default     app3-example-com    nginx   app3.example.com    10.5.5.8,10.5.5.9   80, 443
default     app4-example-com    nginx   app4.example.com    10.5.5.8,10.5.5.9   80, 443

=== 인증서 ===
NAMESPACE   NAME                    READY   SECRET
default     app1-example-com-tls    False   app1-example-com-tls
default     app2-example-com-tls    False   app2-example-com-tls
default     app3-example-com-tls    True    app3-example-com-tls
default     app4-example-com-tls    True    app4-example-com-tls
```

이 표를 보면 위에서 설명한 개념들이 바로 대응된다: `kube-system`의 `coredns-*`가 CoreDNS, `kube-proxy-*`가 kube-proxy, `metallb-system`의 `speaker-*`가 각 노드에 하나씩(DaemonSet), `ingress-nginx-controller-*`가 두 노드에 하나씩(Deployment + anti-affinity), `ext-app*-example-com`이 클러스터 밖 백엔드를 가리키는 Service다.

## 파드별 역할과 배치 이유

같은 파드라도 "왜 그 노드에 떴는지"는 각자 다른 규칙 때문이다. 실제 설정값 기준으로 정리.

1. **etcd-chan08, kube-apiserver-chan08, kube-controller-manager-chan08, kube-scheduler-chan08 (chan08에만)**
   - 역할: 클러스터의 두뇌. etcd는 상태 저장소, kube-apiserver는 모든 요청이 거치는 관문, controller-manager/scheduler는 각각 리소스 상태 맞추기와 파드 배치를 담당한다.
   - 왜 chan08에만: 스케줄러가 배치한 일반 파드가 아니라 "정적 파드"다. kubelet이 `/etc/kubernetes/manifests/`에 있는 파일을 그 노드에서만 직접 읽어서 띄우는 방식이라, `kubeadm init`을 실행한 chan08에만 이 파일들이 있다.
   - 관련 설정: `hostNetwork: true`라서 파드 전용 IP(10.244.x) 없이 노드 IP(10.5.5.8)를 그대로 쓴다.

2. **kube-flannel-ds-* (DaemonSet, 양쪽 노드)**
   - 역할: 파드 네트워크(오버레이) 제공. 서로 다른 노드의 파드끼리 통신 가능하게 해준다.
   - 왜 양쪽에: DaemonSet이라 원칙적으로 모든 노드에 하나씩 뜬다.
   - 관련 설정: toleration이 `{"effect":"NoSchedule","operator":"Exists"}` — key를 지정하지 않은 와일드카드라 "NoSchedule 계열 taint는 뭐가 됐든 다 참는다"는 뜻. 그래서 chan08의 control-plane taint에도 걸리지 않는다.

3. **kube-proxy-* (DaemonSet, 양쪽 노드)**
   - 역할: Service 라우팅 규칙(iptables)을 그 노드에 실제로 심어주는 주체.
   - 왜 양쪽에: 어느 노드로 패킷이 들어오든 그 노드 자신이 라우팅을 처리해야 해서 모든 노드에 필수.

4. **coredns-* (Deployment, replicas 2 — 지금은 우연히 둘 다 chan09)**
   - 역할: 클러스터 내부 DNS.
   - 왜 chan09에 몰려있나: control-plane taint를 참는 toleration은 있어서 chan08에도 뜰 수 있는데, "서로 다른 노드에 뜨면 좋겠다"는 설정이 강제가 아니라 `preferred`(권장)라서 지금은 우연히 둘 다 chan09에 있다. 즉 지금 상태로는 chan09가 죽으면 클러스터 DNS가 통째로 끊긴다 — 아직 손 안 댄 약점.
   - 관련 설정: `podAntiAffinity.preferredDuringSchedulingIgnoredDuringExecution`(weight 100, 강제 아님).

5. **metallb-system/speaker-* (DaemonSet, 양쪽 노드, hostNetwork)**
   - 역할: VIP에 대한 ARP 응답과 리더 선출.
   - 왜 양쪽에: 어느 노드든 VIP를 넘겨받을 수 있어야 해서 모든 노드에 필수. MetalLB 자체 매니페스트에 control-plane/master taint를 명시적으로 참는 toleration이 이미 박혀있다.
   - 관련 설정: `hostNetwork: true` — 실제 네트워크 인터페이스에서 직접 ARP를 다뤄야 해서 파드 네트워크가 아니라 노드 네트워크를 그대로 쓴다.

6. **metallb-system/controller-*, cert-manager 계열 3개 (Deployment, replicas 1, 전부 chan09)**
   - 역할: controller는 어느 노드가 VIP를 받을지 조정하는 두뇌(실제 트래픽 처리는 speaker가 함), cert-manager 3종은 인증서 발급/갱신 처리.
   - 왜 chan09에만: 이 파드들엔 toleration이 아예 없다. 그래서 control-plane taint가 있는 chan08엔 원천적으로 못 뜨고, 남은 노드가 chan09 하나뿐이라 자동으로 그리로 간다. 실제 트래픽 경로에 있는 게 아니라 지금은 이대로 둬도 무방.

7. **ingress-nginx-controller-* (Deployment, replicas 2, 노드당 1개씩)**
   - 역할: 실제 요청을 받아 도메인별로 맞는 백엔드로 라우팅.
   - 왜 노드당 1개씩: [`05-ingress.md`](../lessons/05-ingress.md)에서 의도적으로 만든 구성이다. control-plane taint를 참는 toleration과, "같은 라벨의 파드는 서로 다른 노드에"를 강제하는 anti-affinity(`requiredDuringScheduling`)를 직접 추가했다. coredns와 달리 이건 강제라서 항상 양쪽에 하나씩 뜬다.

8. **cm-acme-http-solver-* (default 네임스페이스, 임시)**
   - 역할: cert-manager가 인증서 발급 순간에만 잠깐 만드는 ACME HTTP-01 챌린지 응답용 파드. 발급이 끝나면 자동으로 사라진다.

## 기본 단위

### 클러스터 / 노드
클러스터는 여러 대의 서버를 묶어서 하나처럼 쓰는 단위다. 그 서버 한 대 한 대를 노드라고 부른다. 우리는 chan08(컨트롤플레인)과 chan09(워커) 2대로 클러스터 하나를 만들었다.

- **컨트롤플레인**: 클러스터 전체를 관리하는 두뇌 역할. API 서버(kubectl이 말 거는 대상), 스케줄러(어느 노드에 뭘 띄울지 결정), etcd(클러스터 상태 저장소) 같은 게 여기서 돈다.
- **워커**: 실제 애플리케이션(파드)이 도는 노드. 컨트롤플레인도 기본적으로 워커 역할을 겸할 수 있는데, 기본값은 "컨트롤플레인엔 일반 파드를 안 올린다"는 정책(Taint)이 걸려있다.

### 파드(Pod)
Kubernetes가 다루는 가장 작은 배포 단위. 컨테이너 하나(또는 몇 개)를 감싼 것이라고 보면 된다. 파드는 언제든 죽었다 다시 만들어질 수 있고, 그때마다 IP가 바뀐다 — 그래서 파드 IP를 직접 기억해서 접속하면 안 되고, 아래 Service를 거쳐야 한다.

### 디플로이먼트(Deployment) / 데몬셋(DaemonSet)
파드를 직접 만들지 않고, "이런 파드를 N개 유지해줘"라고 선언하는 상위 리소스.
- **Deployment**: 지정한 개수(`replicas`)만큼 파드를 유지. 예: ingress-nginx를 `replicas: 2`로 설정해서 chan08·chan09에 하나씩 뜨게 함.
- **DaemonSet**: "모든 노드에 하나씩" 뜨는 특수한 형태. 예: MetalLB의 speaker, kube-proxy가 이 방식.

### 네임스페이스(Namespace)
같은 클러스터 안에서 리소스를 논리적으로 구분하는 폴더 같은 개념. `metallb-system`, `ingress-nginx`, `cert-manager`처럼 컴포넌트별로 네임스페이스를 나눠서 설치한다.

## 네트워킹

### Service — 파드 앞에 붙는 고정 주소
파드는 죽으면 IP가 바뀌니, 그 앞에 "고정된 주소 하나"를 만들어주는 게 Service다. 뒤에 파드가 몇 개든, 어떤 파드가 죽고 새로 뜨든 Service의 주소는 안 바뀐다. 세 종류를 다 써봤다.
- **ClusterIP**: 클러스터 내부에서만 보이는 주소. 기본값. 예: `kubernetes` Service(API 서버), `kube-dns`(CoreDNS).
- **NodePort**: 각 노드의 특정 포트(30000-32767)로 클러스터 밖에서도 접근 가능하게 열어줌.
- **LoadBalancer**: 클라우드에서는 외부 로드밸런서를 자동으로 발급받는 타입인데, 베어메탈엔 그런 게 없어서 MetalLB가 이 역할을 대신 채워준다 (아래 참고).

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
Taint는 노드에 붙이는 "거부 딱지"다. 컨트롤플레인 노드엔 기본적으로 `node-role.kubernetes.io/control-plane:NoSchedule` Taint가 붙어있어서, 일반 파드는 이 노드에 못 뜬다. 그 파드가 "나는 이 딱지 무시하고 뜰 수 있어"라고 선언하는 게 Toleration이다. ingress-nginx를 chan08(컨트롤플레인)에도 띄우려고 Toleration을 추가했다.

### Affinity / Anti-affinity — "같이 뜨게" 또는 "따로 뜨게"
파드를 어디에 스케줄할지에 대한 세밀한 규칙. Anti-affinity로 "같은 라벨을 가진 파드는 서로 다른 노드에 하나씩만" 강제해서, ingress-nginx 파드 2개가 각각 다른 노드에 뜨도록 만들었다(둘 다 chan09에 몰리는 걸 방지).
