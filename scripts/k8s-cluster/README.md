# Kubernetes 클러스터 구축 (Stage 1, 2노드)

chan08(컨트롤플레인) + chan09(워커), CNI는 Flannel. Kubernetes v1.36.4 (dl.k8s.io stable 채널 기준 자동 선택).

## 스크립트 순서

| 순서 | 파일 | 대상 | 내용 |
|------|------|------|------|
| 1 | `01-prereqs.sh` | 양쪽 | swap 비활성화, `br_netfilter`/`overlay` 모듈, sysctl |
| 2 | `02-containerd.sh` | 양쪽 | containerd 설치, `SystemdCgroup = true` |
| 3 | `03-kube-packages.sh` | 양쪽 | pkgs.k8s.io repo 등록, kubeadm/kubelet/kubectl 설치 및 hold |
| 4 | `04-init-control-plane.sh` | chan08만 | `kubeadm init`, kubeconfig 설정, Flannel 설치, join 명령 생성 |
| 5 | `05-join-worker.sh` | chan09만 | `04`에서 만든 `~/join-command.sh`를 미리 복사해둔 뒤 실행 |
| 6 | `06-fix-ufw-forward.sh` | 양쪽 | UFW FORWARD 정책 DROP→ACCEPT (아래 "알려진 이슈" 참고) |

## 알려진 이슈: UFW가 pod 네트워크를 막음

`../provision/04-firewall.sh`로 UFW를 활성화하면 `/etc/default/ufw`의 `DEFAULT_FORWARD_POLICY`가 기본 `DROP`으로 설정된다. 이 상태에서는 iptables `FORWARD` 체인 기본 정책이 DROP이 되어, kube-proxy/Flannel이 만든 규칙에 명시적으로 걸리지 않는 pod→ClusterIP 트래픽이 막힌다. 실제로 CoreDNS가 `[WARNING] plugin/kubernetes: starting server with unsynced Kubernetes API` 상태에서 멈추는 증상으로 나타났다.

`06-fix-ufw-forward.sh`가 `DEFAULT_FORWARD_POLICY`를 `ACCEPT`로 바꾸고 `ufw reload`한다. **인바운드 규칙(10.5.5.0/24 제한)에는 영향 없음** — FORWARD 체인(라우팅되는 트래픽)만 대상. 앞으로 이 서버들에 UFW를 다시 초기화하는 경우 이 스크립트를 반드시 함께 적용해야 한다.

## 검증

```bash
kubectl get nodes -o wide         # chan08, chan09 모두 Ready
kubectl get pods -A               # kube-system, kube-flannel 전부 1/1 Running
kubectl run dns-test --image=busybox:1.36 --restart=Never --command -- sleep 3600
kubectl exec dns-test -- nslookup kubernetes.default.svc.cluster.local
kubectl delete pod dns-test
```

kubeconfig는 chan08의 `~/.kube/config`에 있음 (chan 계정용, `kubectl`은 chan08에서 바로 사용 가능).
