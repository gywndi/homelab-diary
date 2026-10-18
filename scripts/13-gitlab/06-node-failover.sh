#!/bin/bash
# 노드 장애 시 RBD 볼륨의 강제 detach를 자동화하는 컨트롤러를 배포한다.
# 먼저 읽기 + blocklist 권한만 가진 Ceph 클라이언트 키를 만들고 Secret으로 전달한다.
# 실행 위치: kubectl이 되고 chan08(10.5.5.8)에 SSH 접속이 되는 곳.
#
# 사용법: ./06-node-failover.sh

set -euo pipefail

echo "== Ceph 클라이언트 키 준비 (없으면 생성) =="
ssh -o BatchMode=yes chan@10.5.5.8 \
  'sudo cephadm shell -- ceph auth get-or-create client.failover mon "profile rbd" osd "profile rbd-read-only pool=rbd-pool"' >/dev/null 2>&1
KEY=$(ssh -o BatchMode=yes chan@10.5.5.8 'sudo cephadm shell -- ceph auth get-key client.failover 2>/dev/null' | tail -1)
[[ ${#KEY} -eq 40 ]] || { echo "키 조회 실패" >&2; exit 1; }

echo "== 네임스페이스 + 키 Secret =="
kubectl create namespace node-failover --dry-run=client -o yaml | kubectl apply -f -
kubectl -n node-failover create secret generic ceph-failover-key --from-literal=key="$KEY" --dry-run=client -o yaml | kubectl apply -f -

echo "== 컨트롤러 배포 =="
cat <<'EOF' | kubectl apply -f -
# 노드 장애 시 RBD 볼륨의 강제 detach를 자동화하는 컨트롤러.
#
# 배경: RBD PVC(RWO)를 쓰는 파드는 노드가 죽으면 새 노드로 뜨기 전에 죽은 노드의 VolumeAttachment가
# 정리돼야 한다(기본 6분 대기). `node.kubernetes.io/out-of-service` taint를 걸면 즉시 정리되지만
# "노드가 실제로 꺼졌다"는 전제가 필요하다. RBD 이미지는 imageFeatures=layering뿐(exclusive-lock 없음)이라
# 네트워크만 끊긴 살아있는 노드가 계속 쓰면 두 노드가 같은 볼륨에 쓰게 된다.
# 그래서 taint 전에 Ceph에서 해당 노드 IP를 blocklist(펜싱)하고, 그 노드의 watcher가 사라진 것을 확인한다.
#
# 절차(노드마다 10초 주기):
#   1) Ready != True 가 NOTREADY_SECONDS(60초) 이상 지속
#   2) 노드 IP를 Ceph에서 blocklist (BLOCKLIST_SECONDS 동안)
#   3) 그 노드에 attach된 RBD 이미지에서 노드 IP watcher가 사라질 때까지 대기 (최대 40초)
#   4) out-of-service taint 부여
#   노드가 Ready로 복귀하면 taint 제거.
# 가드: 이미 다른 노드가 taint 상태이면 새 노드에는 걸지 않는다(오탐 연쇄 방지).
# DaemonSet인 이유: 3노드 모두에 이미지를 미리 받아두고, 죽은 노드 외의 복제본이 항상 남게 하려는 것.
# 여러 복제본이 동시에 실행돼도 모든 동작이 멱등이라 문제없다.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: node-failover
  namespace: node-failover
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: node-failover
rules:
  - apiGroups: [""]
    resources: [nodes]
    verbs: [get, list, patch]
  - apiGroups: [""]
    resources: [persistentvolumes]
    verbs: [get]
  - apiGroups: [storage.k8s.io]
    resources: [volumeattachments]
    verbs: [get, list]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: node-failover
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: node-failover
subjects:
  - kind: ServiceAccount
    name: node-failover
    namespace: node-failover
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: node-failover-script
  namespace: node-failover
data:
  run.sh: |
    #!/bin/bash
    set -u
    NOTREADY_SECONDS="${NOTREADY_SECONDS:-60}"
    BLOCKLIST_SECONDS="${BLOCKLIST_SECONDS:-300}"
    INTERVAL="${INTERVAL:-10}"
    DRY_RUN="${DRY_RUN:-0}"
    TEST_NODE="${TEST_NODE:-}"          # 점검용: 이 노드를 NotReady로 간주(DRY_RUN=1과 함께 사용)
    TAINT="node.kubernetes.io/out-of-service=nodeshutdown:NoExecute"
    # 키는 인자(--key)로 넘기면 프로세스 목록과 로그에 노출되므로 키링 파일로 전달한다.
    KEYRING=/tmp/client.failover.keyring
    ( umask 077; printf '[client.failover]\n\tkey = %s\n' "$CEPH_KEY" > "$KEYRING" )
    CEPH_ARGS_COMMON=(--mon-host "$CEPH_MONITORS" -n client.failover --keyring "$KEYRING")

    log() { echo "$(date -u +%FT%TZ) $*"; }
    act() { if [ "$DRY_RUN" = 1 ]; then log "[dry-run] $*"; else "$@"; fi; }

    has_taint() { kubectl get node "$1" -o jsonpath='{.spec.taints[*].key}' | grep -qw node.kubernetes.io/out-of-service; }

    # 노드에 attach된 RBD 이미지 목록(pool/image)
    node_images() {
      local node="$1" pv
      for pv in $(kubectl get volumeattachment -o jsonpath="{range .items[?(@.spec.nodeName==\"$node\")]}{.spec.attacher}={.spec.source.persistentVolumeName}{\"\n\"}{end}" \
                  | grep '^rbd.csi.ceph.com=' | cut -d= -f2); do
        kubectl get pv "$pv" -o jsonpath='{.spec.csi.volumeAttributes.pool}/{.spec.csi.volumeAttributes.imageName}{"\n"}'
      done
    }

    node_has_watcher() {  # $1=node IP, $2..=images
      local ip="$1"; shift; local img
      for img in "$@"; do
        rbd "${CEPH_ARGS_COMMON[@]}" status "$img" 2>/dev/null | grep -q "watcher=$ip:" && return 0
      done
      return 1
    }

    handle_down_node() {
      local node="$1" ip images
      has_taint "$node" && return 0
      ip=$(kubectl get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
      for other in $(kubectl get nodes -o name | cut -d/ -f2); do
        [ "$other" != "$node" ] && has_taint "$other" && { log "$node: $other 가 이미 taint 상태라 건너뜀(가드)"; return 0; }
      done
      images=$(node_images "$node")
      log "$node($ip): NotReady ${2}s 지속, attach된 RBD: ${images:-없음}"

      # 펜싱: 이 노드의 Ceph 클라이언트를 차단해 살아있더라도 더는 쓰지 못하게 한다.
      act ceph "${CEPH_ARGS_COMMON[@]}" osd blocklist range add "$ip/32" "$BLOCKLIST_SECONDS"

      # 펜싱 확인: 노드의 watcher가 사라질 때까지 대기
      local i
      for i in 1 2 3 4; do
        if [ "$DRY_RUN" = 1 ]; then
          if node_has_watcher "$ip" $images; then log "[dry-run] $node: 현재 watcher 존재(살아있는 클라이언트) — 실제로는 blocklist 후 소멸 대기"; else log "[dry-run] $node: watcher 없음"; fi
          break
        fi
        node_has_watcher "$ip" $images || { log "$node: watcher 없음 확인"; break; }
        [ "$i" = 4 ] && { log "$node: watcher가 남아 있어 taint 보류"; return 0; }
        sleep 10
      done

      act kubectl taint node "$node" "$TAINT" --overwrite
      log "$node: out-of-service taint 처리 완료"
    }

    log "시작: notready=${NOTREADY_SECONDS}s blocklist=${BLOCKLIST_SECONDS}s dry_run=$DRY_RUN test_node=${TEST_NODE:-없음}"
    while true; do
      now=$(date +%s)
      while read -r node ready since; do
        [ -z "$node" ] && continue
        if [ "$ready" != "True" ] || [ "$node" = "$TEST_NODE" ]; then
          age=$(( now - $(date -d "$since" +%s) ))
          [ "$node" = "$TEST_NODE" ] && age=$NOTREADY_SECONDS
          [ "$age" -ge "$NOTREADY_SECONDS" ] && handle_down_node "$node" "$age"
        elif has_taint "$node"; then
          age=$(( now - $(date -d "$since" +%s) ))
          if [ "$age" -ge 30 ]; then
            act kubectl taint node "$node" node.kubernetes.io/out-of-service-
            log "$node: Ready 복귀, taint 제거"
          fi
        fi
      done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{" "}{.status.conditions[?(@.type=="Ready")].lastTransitionTime}{"\n"}{end}')
      sleep "$INTERVAL"
    done
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-failover
  namespace: node-failover
spec:
  selector:
    matchLabels:
      app: node-failover
  template:
    metadata:
      labels:
        app: node-failover
    spec:
      serviceAccountName: node-failover
      # 노드가 죽어도 다른 복제본이 동작해야 하므로 자기 자신은 eviction 대상이어도 무방. 단 일반 taint는 견딘다.
      tolerations:
        - operator: Exists
      containers:
        - name: controller
          image: quay.io/ceph/ceph:v19
          command: ["/bin/bash", "/scripts/run.sh"]
          env:
            - name: CEPH_MONITORS
              value: 10.5.5.8:6789,10.5.5.9:6789,10.5.5.10:6789
            - name: CEPH_KEY
              valueFrom:
                secretKeyRef:
                  name: ceph-failover-key
                  key: key
            - name: DRY_RUN
              value: "0"
          volumeMounts:
            - { name: script, mountPath: /scripts }
            - { name: kubectl, mountPath: /usr/local/bin/kubectl, readOnly: true }
          resources:
            requests: { cpu: 10m, memory: 64Mi }
            limits: { memory: 256Mi }
      volumes:
        - name: script
          configMap:
            name: node-failover-script
        # 노드에 설치된 kubectl(정적 바이너리)을 재사용한다. 이미지에 kubectl이 없고, 장애 시점에 내려받을 수 없기 때문.
        - name: kubectl
          hostPath:
            path: /usr/bin/kubectl
            type: File
EOF

kubectl -n node-failover rollout restart ds/node-failover
kubectl -n node-failover rollout status ds/node-failover --timeout=600s
kubectl -n node-failover get pods -o wide
