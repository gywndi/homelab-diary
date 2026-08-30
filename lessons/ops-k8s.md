# k8s 운영 명령 모음

[`02-k8s-cluster.md`](02-k8s-cluster.md)/[`06-llm-gpu-node.md`](06-llm-gpu-node.md)로 구축한 3노드(chan08/chan09/llm001, 전부 컨트롤플레인+워커) 클러스터를 평소에 들여다보고 조작할 때 쓰는 명령들. 구축 절차가 아니라 "상태를 확인하고, 뭔가 이상할 때 원인을 좁히는" 용도. 애플리케이션별 운영은 각자 문서 참고 — [ingress](05-2-ingress-ops.md), [StarRocks](08-4-starrocks-ops.md), [Ceph](ops-ceph.md). kubeconfig는 chan08의 `~/.kube/config`(접속 주소 `https://k8s.home:6443`, VIP `10.5.5.3`).

## 클러스터/노드 상태

```bash
# 노드 목록 (Ready, 역할, 버전 한눈에)
kubectl get nodes -o wide

# 특정 노드 상세 (taint, 라벨, 리소스 할당량, 최근 이벤트)
kubectl describe node chan08

# 전체 네임스페이스 파드 상태 (Running/CrashLoopBackOff/Pending 스캔용)
kubectl get pods -A -o wide

# Pending/실패 파드만 걸러보기
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded

# 클러스터 전역 최근 이벤트 (시간순, 원인 파악 1순위)
kubectl get events -A --sort-by=.lastTimestamp | tail -30

# 리소스 사용량 (metrics-server 있어야 동작)
kubectl top nodes
kubectl top pods -A
```

## 파드 troubleshooting

```bash
# 로그 (재시작 전 로그가 필요하면 --previous)
kubectl -n <ns> logs <pod> --tail=100
kubectl -n <ns> logs <pod> --previous

# 여러 컨테이너가 있는 파드는 -c로 지정
kubectl -n <ns> logs <pod> -c <container>

# 왜 안 뜨는지 (Pending/CrashLoopBackOff 원인은 대부분 Events 섹션에 있음)
kubectl -n <ns> describe pod <pod>

# 컨테이너 안에 직접 들어가기
kubectl -n <ns> exec -it <pod> -- bash

# 디버깅용 임시 파드 (이미지에 셸이 없거나 네트워크 테스트할 때)
kubectl run debug --rm -it --image=busybox:1.36 --restart=Never -- sh
```

## 배포 반영/롤아웃

```bash
# ConfigMap/Secret만 바꾸고 파드가 스스로 안 읽어 들이는 경우 강제 재기동
kubectl -n <ns> rollout restart deployment <name>

# 롤아웃 진행 상황 대기 (CI/스크립트에서 다음 단계 조건으로 씀)
kubectl -n <ns> rollout status deployment/<name> --timeout=180s

# 방금 배포가 문제였다면 직전 리비전으로 되돌리기
kubectl -n <ns> rollout undo deployment/<name>

# ConfigMap을 파일에서 다시 만들어 그대로 적용 (내용을 부분 편집할 안전한 방법)
kubectl -n <ns> get configmap <name> -o jsonpath='{.data.<key>}' > /tmp/<key>
# (파일 수정)
kubectl -n <ns> create configmap <name> --from-file=<key>=/tmp/<key> \
  --dry-run=client -o yaml | kubectl apply -f -
```
마지막 패턴(`get -o jsonpath` → 파일 수정 → `create --dry-run=client -o yaml | apply`)은 `kubectl edit`이나 JSON 파이프보다 안전하다 — 실제로 바뀌는 내용을 파일로 직접 눈으로 확인할 수 있고, 다른 키를 실수로 건드릴 위험이 없다.

## 노드 정비 (cordon/drain)

```bash
# 새 파드 스케줄 금지 (재부팅/유지보수 전)
kubectl cordon chan09

# 기존 파드를 다른 노드로 옮기고 이 노드 비우기
kubectl drain chan09 --ignore-daemonsets --delete-emptydir-data

# 정비 끝나면 스케줄 재개
kubectl uncordon chan09
```
이 클러스터는 노드 3대 전부가 컨트롤플레인 겸 워커라([`06-llm-gpu-node.md`](06-llm-gpu-node.md) 참고), 한 노드를 drain하면 워크로드가 나머지 2대에만 몰린다. etcd 쿼럼(과반수 2/3)은 drain과 무관하게 그 노드의 etcd 프로세스가 살아있는 한 유지된다 — drain은 kubelet이 관리하는 파드만 옮기지, static pod로 뜨는 etcd/apiserver 자체를 내리지 않는다.

## API 서버 VIP (keepalived)

3노드 전부가 컨트롤플레인이라 API 서버 VIP(`10.5.5.3`, `k8s.home`)를 keepalived로 나눠 갖는다([`02-k8s-cluster.md`](02-k8s-cluster.md#api-서버-vip-keepalived-구성) 참고).

```bash
# 지금 이 VIP를 누가 들고 있는지 (각 노드에서 실행, 나오면 그 노드가 보유)
ip -4 addr show | grep 10.5.5.3

# keepalived 상태/최근 로그
sudo systemctl status keepalived
sudo journalctl -u keepalived --since '10 min ago'

# 로컬 apiserver 헬스체크가 실제로 통과하는지 (VIP가 안 뜨는 원인 1순위)
curl -sk --max-time 2 -o /dev/null -w '%{http_code}\n' https://127.0.0.1:6443/livez
```

## 인증서

```bash
# apiserver 인증서 만료일 + SAN 목록 확인
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -enddate
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | grep -A2 'Subject Alternative Name'

# kubeadm이 관리하는 모든 인증서 만료일 한 번에
sudo kubeadm certs check-expiration

# 만료 임박 시 전체 갱신 (컨트롤플레인 노드에서, 재시작까지는 별도)
sudo kubeadm certs renew all
```
SAN을 새로 추가해야 하는 경우(도메인 등록 등)는 갱신이 아니라 재발급이 필요하다 — [내부 DNS 문서의 SAN 관련 알려진 이슈](09-internal-dns.md) 참고.

## etcd

```bash
# 스냅샷 백업 (등록된 크론잡: 매일 03:00 KST, 최근 7개 보관)
~/k8s-cluster/09-etcd-backup.sh

# 최근 백업 목록
ls -lt /data/etcd-backup/ | head

# 클러스터 멤버/상태 (쿼럼 확인용, 3대 전부 나와야 정상)
kubectl -n kube-system exec etcd-chan08 -- etcdctl member list \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key -w table

kubectl -n kube-system exec etcd-chan08 -- etcdctl endpoint health \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key
```
etcd 컨테이너 이미지엔 `tar`/`cat`도 없어서 `kubectl cp`가 안 통한다 — 스냅샷은 hostPath(`/var/lib/etcd`)를 거쳐 호스트에서 직접 꺼내야 한다. 자세한 배경은 [`02-k8s-cluster.md`의 관련 알려진 이슈](02-k8s-cluster.md#알려진-이슈-etcd-컨테이너-이미지엔-tarcatrm도-없음) 참고.

## 내부 DNS (CoreDNS)

```bash
# internal-dns(LAN/노드용) 상태
kubectl -n internal-dns get pods -o wide
kubectl -n internal-dns logs -l app=internal-dns --tail=30

# kube-system CoreDNS(파드용) 상태
kubectl -n kube-system get pods -l k8s-app=kube-dns
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=30

# 파드 안에서 실제로 이름이 풀리는지 (stub-domain 위임 확인용)
kubectl run dns-test --image=busybox:1.36 --restart=Never --rm -it --command -- \
  nslookup ceph.home
```
새 `.home` 도메인을 추가했는데 파드에서 안 풀리면 `kube-system` CoreDNS의 `home:53` stub-domain 블록이 아니라 `internal-dns`의 `hosts` 블록 자체를 빠뜨렸을 가능성이 높다 — [내부 DNS](09-internal-dns.md) 참고.

## GPU 노드 (llm001)

```bash
# nvidia.com/gpu 리소스가 스케줄러에 보이는지
kubectl get nodes -o json | jq '.items[] | {name:.metadata.name, gpu:.status.allocatable."nvidia.com/gpu"}'

# device-plugin 파드 상태
kubectl -n kube-system get pods -l name=nvidia-device-plugin-ds -o wide

# 노드 자체에서 드라이버가 살아있는지
ssh 10.5.5.10 nvidia-smi
```

## 방화벽(UFW)이 원인일 때

k8s 트래픽이 막히는 문제의 상당수는 UFW 쪽이다([`02-k8s-cluster.md`](02-k8s-cluster.md#알려진-이슈-ufw가-pod-네트워크를-막음), [`05-1-ingress.md`](05-1-ingress.md#알려진-이슈) 참고).

```bash
# 현재 규칙 전체
sudo ufw status verbose

# 실제로 뭐가 막혔는지 (BLOCK 로그)
sudo journalctl -k | grep 'UFW BLOCK' | tail -20

# FORWARD 체인 기본 정책 확인 (DROP이면 pod-to-pod/ClusterIP가 막힘)
grep DEFAULT_FORWARD_POLICY /etc/default/ufw
```

## kubeconfig / 인증

```bash
# 지금 쓰고 있는 클러스터/서버 주소 확인
kubectl config view --minify

# server 주소만 안전하게 교체 (전체 YAML 수동 편집보다 안전)
kubectl config set-cluster kubernetes --server=https://k8s.home:6443

# 워커/컨트롤플레인 join 명령 재발급 (토큰 24h, cert-key 2h로 매번 만료됨)
kubeadm token create --print-join-command
sudo kubeadm init phase upload-certs --upload-certs   # --control-plane join 시에만 필요
```

## 흔한 장애 체크리스트

- **`kubectl`이 응답 없음**: VIP(`10.5.5.3`)가 어느 노드에도 없는지 확인(`ip -4 addr show | grep 10.5.5.3`, 위 "API 서버 VIP" 참고) — 3노드 전부에서 keepalived가 죽어있으면 apiserver 자체는 살아있어도 VIP로는 접속이 안 된다. IP 대신 각 노드의 로컬 apiserver(`https://<노드 IP>:6443`)로 직접 붙어서 우회 확인 가능.
- **파드가 새 ConfigMap/Secret 내용을 못 읽음**: k8s는 마운트된 ConfigMap을 자동으로 재로드하지만 애플리케이션 프로세스가 파일 변경을 감지 못 하는 경우가 흔하다 — `rollout restart`로 강제 재기동.
- **PVC가 계속 `Pending`**: `kubectl describe pvc <name>`의 Events. ceph-csi 쪽 문제면 `kubectl -n ceph-csi get pods`로 csi 플러그인이 떠 있는지, `cephadm shell -- ceph -s`로 Ceph 클러스터 자체가 HEALTH_OK인지 먼저 확인([ops-ceph.md](ops-ceph.md) 참고).
- **컨트롤플레인 노드에 새로 뜬 파드가 API 서버에 못 붙음**: same-node hairpin이 UFW에 막히는 문제일 수 있다 — [`05-1-ingress.md`의 관련 알려진 이슈](05-1-ingress.md#알려진-이슈) 참고.
- **LoadBalancer(MetalLB) VIP가 아무도 응답 안 함**: 노드에 `node.kubernetes.io/exclude-from-external-load-balancers` 라벨이 붙어있으면 MetalLB가 그 노드를 광고 후보에서 제외한다 — 컨트롤플레인 승격 직후 자주 놓치는 부분. [`06-llm-gpu-node.md`의 관련 알려진 이슈](06-llm-gpu-node.md#컨트롤플레인-승격-시-붙는-exclude-from-external-load-balancers-라벨이-metallb-vip를-통째로-죽임) 참고.
