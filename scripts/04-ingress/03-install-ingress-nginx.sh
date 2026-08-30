#!/bin/bash
# ingress-nginx 설치 + bare-metal 2노드 클러스터에 맞게 조정
#
# 기본 baremetal 매니페스트는 Service가 NodePort이고 replicas=1이라,
# MetalLB로 VIP를 받고 양쪽 노드에 파드가 하나씩 뜨도록 패치한다.
#
# 사용법: ./03-install-ingress-nginx.sh <VIP>
#   예: ./03-install-ingress-nginx.sh 10.5.5.50

set -euo pipefail

VIP="${1:-}"
if [[ -z "$VIP" ]]; then
  echo "사용법: $0 <VIP>" >&2
  exit 1
fi

kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/baremetal/deploy.yaml

echo "== Service를 LoadBalancer로 전환, VIP 고정, 트래픽 정책을 Cluster로 =="
kubectl -n ingress-nginx patch svc ingress-nginx-controller \
  -p "{\"spec\":{\"type\":\"LoadBalancer\",\"externalTrafficPolicy\":\"Cluster\"}}"
kubectl -n ingress-nginx annotate svc ingress-nginx-controller \
  metallb.io/loadBalancerIPs="${VIP}" --overwrite

echo "== 컨트롤플레인 노드에도 뜨도록 replicas/toleration/anti-affinity 패치 =="
kubectl -n ingress-nginx patch deployment ingress-nginx-controller --type=json -p '[
  {"op":"replace","path":"/spec/replicas","value":2},
  {"op":"replace","path":"/spec/strategy","value":{"type":"RollingUpdate","rollingUpdate":{"maxSurge":0,"maxUnavailable":1}}},
  {"op":"add","path":"/spec/template/spec/tolerations","value":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]},
  {"op":"add","path":"/spec/template/spec/affinity","value":{"podAntiAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":[{"labelSelector":{"matchLabels":{"app.kubernetes.io/component":"controller","app.kubernetes.io/instance":"ingress-nginx"}},"topologyKey":"kubernetes.io/hostname"}]}}}
]'

echo "== 롤아웃 대기 =="
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=180s

echo "== 확인 =="
kubectl -n ingress-nginx get pods -o wide
kubectl -n ingress-nginx get svc ingress-nginx-controller
