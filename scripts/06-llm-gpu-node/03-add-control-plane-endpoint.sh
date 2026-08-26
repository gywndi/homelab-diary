#!/bin/bash
# 단일 컨트롤플레인으로 초기화된 클러스터에 공유 진입점(VIP)을 사후 반영
#
# kubeadm은 처음 init할 때 --control-plane-endpoint 없이 만든 클러스터에는
# 컨트롤플레인을 추가로 join시키는 걸 거부한다. ClusterConfiguration에
# controlPlaneEndpoint와 apiserver certSAN을 추가하고, 이미 떠 있는
# apiserver 인증서를 그 SAN을 포함해서 재발급한다.
#
# 기존 컨트롤플레인(예: chan08)에서만 1회 실행.
#
# 사용법: sudo ./03-add-control-plane-endpoint.sh <VIP>
#   예: ./03-add-control-plane-endpoint.sh 10.5.5.3

set -euo pipefail

VIP="${1:-}"
if [[ -z "$VIP" ]]; then
  echo "사용법: $0 <API 서버 VIP>" >&2
  exit 1
fi

SELF_IP="$(hostname -I | awk '{print $1}')"
CONFIG_FILE="/tmp/kubeadm-cluster-config.yaml"

echo "== 현재 ClusterConfiguration에 controlPlaneEndpoint/certSAN 추가 =="
kubectl -n kube-system get cm kubeadm-config -o jsonpath='{.data.ClusterConfiguration}' > "$CONFIG_FILE"
python3 - "$CONFIG_FILE" "$VIP" <<'PYEOF'
import sys
path, vip = sys.argv[1], sys.argv[2]
with open(path) as f:
    content = f.read()
content = content.replace("apiServer: {}", f"apiServer:\n  certSANs:\n  - {vip}")
content += f"controlPlaneEndpoint: {vip}:6443\n"
with open(path, "w") as f:
    f.write(content)
PYEOF

kubectl -n kube-system create cm kubeadm-config \
  --from-file=ClusterConfiguration="$CONFIG_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "== apiserver 인증서 재발급 (기존 파일 백업 후 강제 재생성) =="
cp /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.crt.bak
cp /etc/kubernetes/pki/apiserver.key /etc/kubernetes/pki/apiserver.key.bak
rm /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.key
kubeadm init phase certs apiserver --config "$CONFIG_FILE"

echo "== apiserver 정적 파드 강제 재기동 (새 인증서 반영) =="
mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/kube-apiserver.yaml.tmp
sleep 5
mv /tmp/kube-apiserver.yaml.tmp /etc/kubernetes/manifests/kube-apiserver.yaml
sleep 10

echo "== admin.conf도 VIP로 갱신 (kubelet/controller-manager/scheduler.conf는 각자 자기 IP를 그대로 씀 - 정상) =="
sed -i "s#https://${SELF_IP}:6443#https://${VIP}:6443#" /etc/kubernetes/admin.conf
cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
chown "$(logname)":"$(logname)" "$HOME/.kube/config" || true

echo "== 확인 =="
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | grep -A2 'Subject Alternative Name'
kubectl get nodes

echo "완료: controlPlaneEndpoint=${VIP}:6443 반영. 다음은 04-setup-apiserver-vip-keepalived.sh로 VIP를 띄울 것"
