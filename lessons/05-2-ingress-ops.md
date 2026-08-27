# Ingress + 인증서 운영 명령 모음

[`05-1-ingress.md`](05-1-ingress.md)로 구축한 뒤 실제 운영하면서 반복적으로 쓰는 명령들. 구축 절차가 아니라 "평소에 확인하고, 뭔가 이상할 때 들여다보는" 용도.

## 전체 상태 한눈에 보기

```bash
# VIP가 정상적으로 할당되어 있는지
kubectl -n ingress-nginx get svc ingress-nginx-controller

# ingress-nginx 파드가 양쪽 노드에 다 떠있는지
kubectl -n ingress-nginx get pods -o wide

# 등록된 도메인과 인증서 발급 상태를 한 번에
kubectl get ingress
kubectl get certificate
```

## 도메인 추가/제거

```bash
# 새 도메인 추가 (staging으로 먼저 검증)
../scripts/05-ingress/07-add-domain.sh app3.example.com 10.5.5.7 8080 staging

# 검증되면 production으로 전환
kubectl annotate ingress app3-example-com \
  cert-manager.io/cluster-issuer=letsencrypt-prod --overwrite

# 도메인 제거 (Ingress/Service/EndpointSlice/발급된 인증서까지 정리)
kubectl delete ingress app3-example-com
kubectl delete service ext-app3-example-com
kubectl delete endpointslice ext-app3-example-com
kubectl delete certificate app3-example-com-tls
kubectl delete secret app3-example-com-tls
```

## 인증서 상태 확인 / 강제 재발급

```bash
# 특정 도메인 인증서 상세 상태 (만료일, 최근 이벤트)
kubectl describe certificate app1-example-com-tls

# 진행 중인 발급 요청/챌린지 확인 (staging/prod 전환 직후 등)
kubectl get order,challenge -A

# 챌린지가 pending에서 안 넘어갈 때 원인 확인 (DNS 미설정 vs 설정 오류 구분)
kubectl describe challenge <challenge 이름>

# 인증서 강제 재발급 (Secret을 지우면 cert-manager가 다시 발급함)
kubectl delete secret app1-example-com-tls
```

## MetalLB 상태 확인

```bash
# 지금 VIP를 누가(어느 노드가) 응답하고 있는지
kubectl -n metallb-system get pods -o wide
kubectl -n metallb-system logs -l component=speaker --tail=20

# IP 대역/광고 설정 확인
kubectl -n metallb-system get ipaddresspool,l2advertisement
```

## VIP를 다른 IP로 옮기기

```bash
# IPAddressPool 자체를 바꾸면 됨 (진행 중인 연결은 끊길 수 있음)
kubectl patch ipaddresspool ingress-pool -n metallb-system --type=merge \
  -p '{"spec":{"addresses":["10.5.5.2/32"]}}'

# Service에 고정해둔 IP annotation도 같이 갱신
kubectl -n ingress-nginx annotate svc ingress-nginx-controller \
  metallb.io/loadBalancerIPs=10.5.5.2 --overwrite
```

## 흔한 장애 체크리스트

- **VIP에 접속이 안 됨**: `kubectl -n metallb-system get pods -o wide`로 speaker가 양쪽 다 Running인지, `arp -a`로 VIP의 MAC이 실제 노드 것과 일치하는지 확인.
- **502/504가 뜸**: 백엔드(EndpointSlice에 등록한 외부 IP:포트)가 살아있는지 직접 `curl`로 확인. Ingress가 가리키는 Service 이름/포트가 실제 EndpointSlice와 일치하는지도 확인.
- **인증서가 계속 pending**: `kubectl describe challenge`의 Reason을 본다. `no such host`면 DNS 미설정, `connection refused`/`timeout`이면 라우터 포트포워딩이나 방화벽 문제.
- **새로 스케줄된 파드가 이상하게 API 서버에 못 붙음**: 컨트롤플레인 노드에 파드가 새로 뜬 경우라면 [`05-1-ingress.md`의 "컨트롤플레인 파드-호스트 방화벽 수정"](05-1-ingress.md#알려진-이슈) 문제일 수 있다. `sudo journalctl -k | grep 'UFW BLOCK'`으로 확인.
