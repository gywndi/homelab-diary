# GitLab (소스 저장소 + CI/CD)

[← 이전: LLM 서빙](12-llm-serving.md)

k8s 위에 자체 호스팅 GitLab을 세운다. 소스 코드를 저장하고, 코드가 바뀔 때마다 테스트와 배포를 자동으로 돌리는 CI/CD(Continuous Integration/Continuous Delivery, 변경을 계속 합치고 계속 배포하는 자동화 흐름)의 기반이다. 이 문서는 GitLab 본체와 그 주변(접속·인증서·백업·장애 전환)에 더해, 파이프라인을 실제로 돌리는 Runner(CI 작업을 실행하는 에이전트)까지 다룬다. Snowflake dbt 파이프라인은 별도 저장소 `snowflake-dbt`에서 이 Runner 위에 구성했다.

## 목적

GitLab 기반 CI/CD로 다양한 배포 환경을 시험하는 것이 최종 목표다. 첫 번째 대상은 Snowflake(클라우드 데이터 웨어하우스)의 dbt(SQL 변환을 코드로 관리하는 도구) 환경이다. 그 전에 GitLab 자체가 믿고 쓸 만해야 한다. 그래서 다음 네 가지를 먼저 갖춘다.

- 노드가 죽어도 다른 노드에서 다시 뜬다.
- 어디서나 경고 없이 HTTPS로 접속된다.
- 데이터가 NAS에 백업된다.
- 인터넷에 공개돼도 아무나 계정을 만들 수 없다.

## 구성 한눈에

| 요소 | 값 | 역할 |
|---|---|---|
| GitLab CE | `gitlab/gitlab-ce:19.4.2-ce.0`, 파드 1개 | 웹 UI, git 저장소, DB(PostgreSQL), 캐시(Redis)를 한 컨테이너에 담은 Omnibus 이미지 |
| 웹 접속 | `https://gitlab.example.com` → ingress VIP `10.5.5.50` | HTTPS는 ingress-nginx가 종료하고 파드에는 HTTP로 전달 |
| git SSH 접속 | `gitlab-ssh.k8s.home` → MetalLB VIP `10.5.5.55`:22 | ingress는 HTTP만 다루므로 SSH는 별도 VIP |
| 데이터 | PVC `gitlab-data` 100Gi (`ceph-csi-rbd`) | Ceph RBD 블록 볼륨, 노드와 무관하게 보존 |
| 백업 보관 | PVC `gitlab-backup` 50Gi (`nfs-nas`) | NAS에 보관 |
| 장애 전환 | `node-failover` 네임스페이스의 DaemonSet | 노드가 죽으면 볼륨을 안전하게 풀어주는 컨트롤러 |
| CI Runner | `gitlab/gitlab-runner:alpine-v19.4.1`, `gitlab-runner` 네임스페이스 | CI 작업마다 파드를 하나씩 띄워 실행하는 Kubernetes executor |

## 설계 결정

- **Helm 차트 대신 Omnibus 이미지 단일 파드.** 공식 Helm 차트는 웹·Sidekiq(백그라운드 작업)·Gitaly(git 저장 계층)·PostgreSQL·Redis를 각각 파드로 나눠서 메모리를 많이 쓴다. Omnibus 이미지는 이 모두를 한 컨테이너에 담아 4~6GB로 돈다. 홈랩 규모에서는 이쪽이 단순하고 가볍다.
- **k8s 위에 올린다.** VM에 올리는 안도 검토했다. 하지만 스토리지(Ceph)가 이미 k8s와 분리돼 있어서 클러스터를 다시 세워도 RBD 볼륨은 남는다. ingress·cert-manager·MetalLB·내부 DNS를 그대로 쓸 수 있는 점도 이득이다.
- **Deployment(replicas=1) + `Recreate` 전략 + 명시적 PVC.** MySQL과 같은 패턴이다. RBD는 한 번에 한 노드에만 붙는 볼륨(RWO, ReadWriteOnce)이다. `Recreate`는 옛 파드가 완전히 끝난 뒤에 새 파드를 띄워서 볼륨 인계가 안전하다.
- **`nodeSelector`를 두지 않는다.** 노드 장애 때 어느 노드로든 옮겨 가야 하기 때문이다.
- **데이터·설정·로그를 PVC 하나에 `subPath`로 나눈다.** 볼륨이 하나여야 장애 때 붙고 떼는 작업도 한 번이다.
- **TLS는 ingress에서 끝낸다.** 파드 안 nginx는 HTTP만 받는다. 이때 파드 안 nginx가 요청을 http로 오인하지 않도록 `X-Forwarded-Proto: https` 헤더를 고정한다.
- **공인 도메인 + Let's Encrypt(HTTP-01).** 사설 CA(Vault PKI)를 먼저 구성했다. 하지만 VPN으로 접속하는 기기마다 CA를 신뢰 등록해야 했다. 공인 도메인에 Let's Encrypt 인증서를 쓰면 기기에 아무것도 설치하지 않아도 경고가 없다. 이미 있는 `letsencrypt-prod` 발급자와 같은 방식이다. 사설 CA 구성은 사내 전용 이름용 대안으로 남겼다.
- **인터넷에 공개되므로 회원가입을 끈다.** 공유기가 80/443을 ingress로 포워딩해서, 공인 도메인은 곧 외부 공개다. 이 상태에서는 출발지 IP로 접속을 제한할 수 없다. ingress 서비스가 `externalTrafficPolicy: Cluster`라서 요청의 출발지가 노드 대역으로 바뀌기 때문이다. 대신 가입을 막고 관리자 계정에 2FA(2단계 인증)를 건다.
- **백업은 NAS에 root로 복사한다.** NAS는 root만 쓸 수 있고 GitLab의 실행 계정은 쓰기가 거부된다. 그래서 GitLab은 로컬에 백업을 만들고, 같은 파드 안에서 root로 NAS 마운트에 복사한다. 설정 파일(`gitlab-secrets.json` 포함)도 같이 보관한다. 이 파일이 없으면 데이터베이스 백업만으로는 2FA 비밀키 같은 암호화된 값을 복호화할 수 없다.
- **장애 전환은 세 단계로 짧게 한다.** 노드가 죽으면 파드가 옮겨 가야 한다. 이때 기본값은 파드 퇴출 대기 300초에 볼륨 강제 해제 대기 최대 6분이다. 파드의 퇴출 대기를 5초로 줄이고, 볼륨은 컨트롤러가 안전을 확인한 뒤 즉시 풀어준다.
- **볼륨을 풀기 전에 Ceph에서 해당 노드를 차단(펜싱)한다.** 이 클러스터의 RBD 이미지는 `layering` 기능만 켜져 있고 `exclusive-lock`이 없다. 그래서 노드가 죽은 게 아니라 네트워크만 끊긴 경우에 그대로 볼륨을 풀면, 두 노드가 같은 볼륨에 쓸 수 있다. 컨트롤러는 먼저 노드 IP를 Ceph의 blocklist(차단 목록)에 넣어 그 노드의 쓰기를 막는다.

## 대상

| 항목 | 값 |
|---|---|
| 네임스페이스 | `gitlab` |
| 웹 VIP | `10.5.5.50` (기존 ingress-nginx) |
| SSH VIP | `10.5.5.55` |
| 공인 도메인 | `gitlab.example.com` |
| 이미지 | `gitlab/gitlab-ce:19.4.2-ce.0` |
| 노드 | chan08, chan09, llm001 중 어디든 (고정 안 함) |

## 스크립트 목록 (이름 순)

### SSH 전용 VIP 풀 등록
- 설명: git SSH용 VIP `10.5.5.55`를 MetalLB(베어메탈용 로드밸런서)에 등록한다. SSH(22번)는 ingress가 다루지 못해서 별도 LoadBalancer VIP가 필요하다. `10.5.5.52`~`10.5.5.54`는 StarRocks VM이 쓰고 있어 피했다.
- 스크립트: [`01-metallb-ssh-pool.sh`](../scripts/13-gitlab/01-metallb-ssh-pool.sh)

```bash
# IP 풀과 L2 광고(같은 LAN에서 이 IP를 ARP로 알리는 설정)를 한 번에 만든다
kubectl apply -f - <<'EOF'
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: gitlab-pool
  namespace: metallb-system
spec:
  addresses:
    - 10.5.5.55/32
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: gitlab-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - gitlab-pool
EOF
```

### GitLab 배포
- 설명: 네임스페이스, PVC 2개, Deployment, Service 2개, Ingress를 한 번에 만든다. 인자로 공인 도메인을 받는다.
- 스크립트: [`02-deploy-gitlab.sh`](../scripts/13-gitlab/02-deploy-gitlab.sh)

```bash
# 모든 리소스를 한 번에 적용한다 (내용은 아래 표와 설정 블록 참고)
kubectl apply -f - <<EOF
...
EOF

# 최초 기동이 끝날 때까지 기다린다 (DB 초기화 때문에 수 분 걸린다)
kubectl -n gitlab rollout status deploy/gitlab --timeout=900s

# 생성된 리소스를 확인한다
kubectl -n gitlab get pods,pvc,svc,ingress
```

적용되는 리소스와 각 설정의 이유는 다음과 같다.

| 리소스 | 핵심 설정 | 이유 |
|---|---|---|
| PVC `gitlab-data` | 100Gi, `ceph-csi-rbd`, RWO | 저장소와 DB를 노드와 무관하게 보존한다. |
| PVC `gitlab-backup` | 50Gi, `nfs-nas`, RWX | 백업을 NAS에 둔다. NFS는 여러 노드에서 동시에 붙을 수 있다. |
| Deployment | `replicas: 1`, `strategy: Recreate` | 단일 인스턴스이고 RWO 볼륨이라 옛 파드가 끝난 뒤에 새 파드를 띄워야 한다. |
| `tolerations` | `unreachable`, `not-ready` 각 `tolerationSeconds: 5` | 노드 장애 때 퇴출 대기를 기본 300초에서 5초로 줄인다. |
| `/dev/shm` | `emptyDir` (Memory) 512Mi | GitLab이 공유 메모리를 쓴다. 기본 크기는 너무 작다. |
| 리소스 | `requests.memory: 4Gi`, `limits.memory: 8Gi` | Omnibus 한 파드가 쓰는 범위에 맞춘다. |
| `startupProbe` | `/-/readiness`, 10초 간격, 90회 | 최초 기동은 10분 넘게 걸릴 수 있어 넉넉히 기다린다. |
| Service `gitlab-http` | ClusterIP 80 | ingress가 전달할 대상이다. |
| Service `gitlab-ssh` | LoadBalancer, `10.5.5.55`, `externalTrafficPolicy: Local` | SSH 전용 VIP이다. 풀과 IP를 어노테이션으로 명시한다. |
| Ingress | `letsencrypt-prod`, TLS 시크릿 `gitlab-tls` | 공인 인증서를 자동 발급하고 갱신한다. |

GitLab 설정은 `GITLAB_OMNIBUS_CONFIG` 환경변수로 주입한다. 이 값이 컨테이너 안 `gitlab.rb`가 된다.

```ruby
# 사용자가 보는 주소다. 링크와 리다이렉트가 이 값으로 만들어진다
external_url 'https://gitlab.example.com'

# 파드 안 nginx는 HTTP 80만 받는다. TLS는 ingress가 종료한다
nginx['listen_port'] = 80
nginx['listen_https'] = false

# ingress가 https로 받았다는 사실을 GitLab에 알린다
nginx['proxy_set_headers'] = { 'X-Forwarded-Proto' => 'https', 'X-Forwarded-Ssl' => 'on' }

# 로컬(RBD) 백업은 3일만 보관한다. 장기 보관본은 NAS로 복사한다
gitlab_rails['backup_keep_time'] = 259200

# git clone 주소의 SSH 호스트와 포트다
gitlab_rails['gitlab_shell_ssh_port'] = 22
gitlab_rails['gitlab_ssh_host'] = 'gitlab-ssh.k8s.home'

# 시간대
gitlab_rails['time_zone'] = 'Asia/Seoul'

# kubelet의 헬스체크는 노드의 CNI 주소(10.244.x.1)로 들어온다. 허용하지 않으면 /-/readiness가 404를 준다
gitlab_rails['monitoring_whitelist'] = ['127.0.0.0/8', '10.244.0.0/16']

# 메모리를 아끼려고 내장 모니터링과 레지스트리를 끈다
prometheus_monitoring['enable'] = false
registry['enable'] = false

# 웹 서버(Puma) 프로세스 수, Sidekiq 동시 작업 수, DB 버퍼
puma['worker_processes'] = 2
sidekiq['concurrency'] = 10
postgresql['shared_buffers'] = '256MB'
```

### 내부 DNS에 GitLab 이름 등록
- 설명: 내부 DNS(CoreDNS)에 이름 두 개를 직접 등록한다. `gitlab-ssh.k8s.home`은 `10.5.5.55`로 보낸다. SSH는 ingress를 거치지 않고 VIP로 바로 가야 하기 때문이다. 공인 도메인(`gitlab.example.com`)은 `10.5.5.50`으로 보낸다. 공유기 DNS가 새 이름에 간헐적으로 NXDOMAIN을 주기 때문에, 공유기에 묻지 않고 내부 DNS가 직접 답하게 한다.
- 스크립트: [`03-add-ssh-dns.sh`](../scripts/13-gitlab/03-add-ssh-dns.sh)

```bash
# Corefile의 hosts 블록 끝(fallthrough 바로 위)에 한 줄을 추가한 패치를 만든다
kubectl -n internal-dns get cm internal-dns-corefile -o json | python3 -I -c "..." > /tmp/corefile-patch.json

# ConfigMap에 패치를 적용한다
kubectl -n internal-dns patch cm internal-dns-corefile --type merge --patch-file /tmp/corefile-patch.json

# ConfigMap 마운트 갱신이 늦을 수 있어 재시작으로 즉시 반영한다
kubectl -n internal-dns rollout restart deploy/internal-dns

# 재시작이 끝날 때까지 기다린다
kubectl -n internal-dns rollout status deploy/internal-dns
```

추가되는 줄은 `10.5.5.55 gitlab-ssh.k8s.home`과 `10.5.5.50 gitlab.example.com` 두 개다. 이렇게 하면 내부 DNS를 쓰는 기기는 공유기의 헤어핀 NAT(내부에서 공인 IP로 나갔다 돌아오는 경로)를 거치지 않고 ingress에 직접 닿는다.

### 회원가입 비활성화
- 설명: 셀프 회원가입을 끈다. 공인 도메인이라 인터넷에서 가입 화면에 닿기 때문이다. 이후 계정은 관리자가 Admin > Users에서 직접 만든다.
- 스크립트: [`04-disable-signup.sh`](../scripts/13-gitlab/04-disable-signup.sh)

```bash
# 애플리케이션 설정에서 가입 허용을 false로 바꾼다
kubectl -n gitlab exec deploy/gitlab -- gitlab-rails runner 'ApplicationSetting.current.update!(signup_enabled: false); puts "signup_enabled=#{ApplicationSetting.current.signup_enabled}"'
```

이 설정은 DB에 저장되어 파드가 재시작해도 유지된다. 관리자 계정의 2FA는 GitLab 웹 UI의 프로필 설정에서 켠다. 인증 앱(TOTP, 시간 기반 일회용 비밀번호)이면 무엇이든 쓸 수 있다.

### 일일 백업 CronJob
- 설명: 매일 03:00(Asia/Seoul)에 앱 데이터 백업과 설정 백업을 NAS로 복사하고 14일 지난 파일을 지운다. 백업은 `kubectl exec`로 GitLab 파드 안에서 실행한다. CronJob 파드는 `alpine` 이미지에 노드의 `kubectl` 바이너리를 마운트해서 쓴다.
- 스크립트: [`05-backup-cronjob.sh`](../scripts/13-gitlab/05-backup-cronjob.sh)

```bash
# ServiceAccount, 최소 권한 Role(파드 조회·exec), RoleBinding, CronJob을 만든다
kubectl apply -f - <<'EOF'
...
EOF
```

CronJob이 GitLab 파드 안에서 실행하는 명령은 다음과 같다.

```bash
# 저장소·DB·업로드를 하나의 tar로 만든다 (STRATEGY=copy는 쓰는 중에도 일관된 복사본을 보장한다)
gitlab-backup create STRATEGY=copy CRON=1

# 가장 최근 백업 tar를 NAS 마운트로 복사한다
cp "$(ls -t /var/opt/gitlab/backups/*_gitlab_backup.tar | head -1)" /mnt/nas-backup/

# 설정 디렉터리(gitlab-secrets.json 포함)를 압축해서 NAS에 둔다
tar czf /mnt/nas-backup/gitlab-config_<타임스탬프>.tgz -C /etc gitlab

# NAS에서 14일 지난 파일을 삭제한다
find /mnt/nas-backup -type f -mtime +14 -delete
```

`<타임스탬프>`는 실행 시각으로 매번 달라지는 값이라 고정할 수 없다.

### 노드 장애 전환 컨트롤러
- 설명: 노드가 죽었을 때 RBD 볼륨을 안전하게 풀어주는 컨트롤러다. 먼저 읽기와 blocklist 권한만 가진 Ceph 클라이언트를 만들고, 그 키를 Secret으로 전달한 뒤 DaemonSet을 배포한다. DaemonSet인 이유는 세 가지다. 3노드에 이미지를 미리 받아 두고, 죽은 노드 외의 복제본이 항상 남게 하고, 모든 동작이 멱등이라 복제본이 여럿이어도 안전하기 때문이다.
- 스크립트: [`06-node-failover.sh`](../scripts/13-gitlab/06-node-failover.sh)

```bash
# 읽기(rbd-read-only)와 차단(profile rbd) 권한만 가진 Ceph 클라이언트를 만든다
ssh chan@10.5.5.8 'sudo cephadm shell -- ceph auth get-or-create client.failover mon "profile rbd" osd "profile rbd-read-only pool=rbd-pool"'

# 만든 키를 읽어 온다
ssh chan@10.5.5.8 'sudo cephadm shell -- ceph auth get-key client.failover'

# 컨트롤러가 쓸 네임스페이스를 만든다
kubectl create namespace node-failover

# 키를 Secret으로 저장한다 (키는 클러스터마다 다르게 생성되므로 <Ceph 클라이언트 키>로 표기한다)
kubectl -n node-failover create secret generic ceph-failover-key --from-literal=key=<Ceph 클라이언트 키>

# ServiceAccount, ClusterRole(노드 patch, VolumeAttachment 조회), ConfigMap(스크립트), DaemonSet을 적용한다
kubectl apply -f - <<'EOF'
...
EOF

# 설정이 바뀐 스크립트를 반영하려고 재시작한다
kubectl -n node-failover rollout restart ds/node-failover

# 3노드 모두 뜰 때까지 기다린다
kubectl -n node-failover rollout status ds/node-failover --timeout=600s
```

컨트롤러는 10초마다 노드 상태를 보고, 노드가 NotReady 상태로 60초 이상 지속되면 다음 순서로 동작한다.

```bash
# 1. 그 노드에 붙어 있는 RBD 이미지를 찾는다 (VolumeAttachment → PV → 풀/이미지 이름)
kubectl get volumeattachment -o jsonpath='...'

# 2. 그 노드의 Ceph 클라이언트를 300초 동안 차단한다 (chan08/chan09/llm001 각각 해당 노드 IP)
ceph --mon-host 10.5.5.8:6789,10.5.5.9:6789,10.5.5.10:6789 -n client.failover --keyring /tmp/client.failover.keyring osd blocklist range add 10.5.5.8/32 300
ceph --mon-host 10.5.5.8:6789,10.5.5.9:6789,10.5.5.10:6789 -n client.failover --keyring /tmp/client.failover.keyring osd blocklist range add 10.5.5.9/32 300
ceph --mon-host 10.5.5.8:6789,10.5.5.9:6789,10.5.5.10:6789 -n client.failover --keyring /tmp/client.failover.keyring osd blocklist range add 10.5.5.10/32 300

# 3. 그 노드가 이미지의 watcher(열어 둔 클라이언트)에서 사라졌는지 최대 40초 동안 확인한다
rbd --mon-host 10.5.5.8:6789,10.5.5.9:6789,10.5.5.10:6789 -n client.failover --keyring /tmp/client.failover.keyring status rbd-pool/<이미지 이름>

# 4. 안전이 확인되면 out-of-service taint를 건다 (이 taint가 있으면 k8s가 볼륨을 즉시 강제로 푼다)
kubectl taint node chan08 node.kubernetes.io/out-of-service=nodeshutdown:NoExecute
kubectl taint node chan09 node.kubernetes.io/out-of-service=nodeshutdown:NoExecute
kubectl taint node llm001 node.kubernetes.io/out-of-service=nodeshutdown:NoExecute

# 5. 노드가 Ready로 30초 이상 복귀하면 taint를 지운다
kubectl taint node chan09 node.kubernetes.io/out-of-service-
```

`<이미지 이름>`은 PV가 만들어질 때마다 달라지는 UUID라서 고정할 수 없다. 다른 노드에 이미 taint가 걸려 있으면 새 노드에는 걸지 않는다. 오탐이 연쇄적으로 번지는 것을 막기 위한 가드다.

키는 `--key` 인자가 아니라 키링 파일(`/tmp/client.failover.keyring`)로 넘긴다. 인자로 넘기면 프로세스 목록과 로그에 키가 노출된다.

### Vault 사설 CA 발급 체계 (대안 구성)
- 설명: Vault를 사설 CA로 쓰고 cert-manager가 Vault에서 인증서를 받게 한다. 현재 GitLab은 이 구성을 쓰지 않는다. 사내 전용 이름처럼 공인 인증서를 받을 수 없는 서비스용으로 남겨 두었다. cert-manager는 정적 토큰 없이 Vault의 Kubernetes 인증으로 로그인한다.
- 스크립트: [`07-vault-pki-issuer.sh`](../scripts/13-gitlab/07-vault-pki-issuer.sh)

```bash
# 별도 PKI 마운트를 만든다 (기존 테스트용 pki와 분리)
vault secrets enable -path=pki-home pki

# 최대 수명을 10년으로 올린다 (root CA 자신의 수명용)
vault secrets tune -max-lease-ttl=87600h pki-home

# root CA를 만들고 인증서를 파일로 저장한다
vault write -field=certificate pki-home/root/generate/internal common_name="homelab-root-ca" ttl=87600h

# 발급 규칙: k8s.home 하위 이름만, 최대 90일, CN 없는 요청 허용 (ingress가 만드는 요청에는 CN이 없다)
vault write pki-home/roles/k8s-home allowed_domains="k8s.home" allow_subdomains=true require_cn=false max_ttl="2160h"

# cert-manager가 서명 경로 하나만 쓰도록 정책을 만든다
vault policy write cert-manager-pki -

# cert-manager의 ServiceAccount가 그 정책으로 로그인하게 역할을 연결한다
vault write auth/kubernetes/role/cert-manager bound_service_account_names=vault-issuer bound_service_account_namespaces=cert-manager policies=cert-manager-pki ttl=10m

# cert-manager 쪽에 ServiceAccount, 토큰 발급 권한, ClusterIssuer(vault-home)를 만든다
kubectl apply -f - <<'EOF'
...
EOF
```

### GitLab Runner (CI 작업 실행기)
- 설명: CI 작업을 실제로 실행하는 Runner를 k8s에 설치한다. Runner 본체는 Deployment 1개이고, 작업이 들어오면 같은 네임스페이스에 파드를 하나 띄워 실행한 뒤 지운다(Kubernetes executor). 그래서 작업 환경이 매번 깨끗하고, 노드 자원은 작업 시간 동안만 쓴다. 인증 토큰은 GitLab에서 인스턴스 Runner를 만들어 받고 Secret에만 저장한다. 이미 Secret이 있으면 Runner를 새로 만들지 않는다.
- 스크립트: [`08-gitlab-runner.sh`](../scripts/13-gitlab/08-gitlab-runner.sh)

```bash
# Runner 전용 네임스페이스를 만든다
kubectl create namespace gitlab-runner --dry-run=client -o yaml | kubectl apply -f -

# GitLab 안에서 인스턴스 Runner를 만들고 인증 토큰을 받는다 (태그 k8s, 태그 없는 작업도 받는다)
kubectl -n gitlab exec deploy/gitlab -- gitlab-rails runner '...'

# 받은 토큰을 Secret에 저장한다
kubectl -n gitlab-runner create secret generic runner-token --from-literal=token=<인증 토큰>

# ServiceAccount, 최소 권한 Role, RoleBinding, ConfigMap, Deployment를 한 번에 적용한다
kubectl apply -f - <<'EOF'
...
EOF

# Runner 파드가 뜰 때까지 기다린다
kubectl -n gitlab-runner rollout status deploy/gitlab-runner --timeout=300s
```

`<인증 토큰>`은 Runner를 만들 때마다 새로 발급되어 고정할 수 없다.

- **권한은 이 네임스페이스 안으로 한정한다.** Role은 파드·시크릿·컨피그맵·서비스 조작과 `pods/exec`, `pods/log`만 허용한다.
- **토큰을 ConfigMap에 두지 않는다.** `config.toml`은 토큰 자리(`__TOKEN__`)만 비워 ConfigMap에 두고, 컨테이너가 시작될 때 Secret 값으로 치환해 `emptyDir`에 쓴다.
- **동시 작업은 4개다.** 요청도 병렬 4개로 보낸다. 1이면 긴 폴링 때문에 작업 시작이 늦어질 수 있다.
- **작업 파드의 기본 이미지는 `alpine:3.20`이다.** 파이프라인에서 `image`를 지정하면 그 이미지로 바뀐다.
- **작업 파드의 자원 상한은 CPU 2코어, 메모리 2Gi다.**

## 알려진 이슈

### kubelet 헬스체크가 404를 받는다
GitLab의 `/-/readiness`는 기본적으로 로컬 주소에서만 응답한다. kubelet은 노드의 CNI 주소로 접근하므로 404를 받아서 파드가 Ready가 되지 못한다. `monitoring_whitelist`에 파드 대역(`10.244.0.0/16`)을 추가해 해결했다.

### MetalLB가 의도하지 않은 풀의 IP를 준다
여러 풀이 `autoAssign`이 켜져 있으면 Service에 풀을 지정하지 않을 때 아무 풀에서나 IP를 받는다. SSH Service가 옛 RGW 풀의 IP를 받았다. `metallb.io/address-pool`과 `metallb.io/loadBalancerIPs` 어노테이션으로 풀과 IP를 명시해 해결했다.

### NAS에서 GitLab 실행 계정이 쓸 수 없다
NAS는 root로 만든 디렉터리에 다른 계정이 쓰는 것을 거부한다. `chown`과 `chmod 777`을 해도 마찬가지였다. GitLab 계정으로 직접 쓰는 방식을 포기하고, 파드 안에서 root로 복사하는 방식으로 바꿨다.

### Vault 발급이 CN 필수 때문에 실패한다
ingress가 만드는 인증서 요청(CSR)에는 CN이 없고 SAN(대체 이름)만 있다. role의 기본값이 CN을 필수로 요구해서 거부됐다. `require_cn=false`로 바꿨다. 한 번 실패한 Certificate는 재시도 대기에 묶이므로 삭제해서 새로 만들게 했다.

### RBD 이미지에 exclusive-lock이 없다
`ceph-csi-rbd` StorageClass의 `imageFeatures`가 `layering`뿐이다. 그래서 RBD의 이중 마운트 방지 기능이 이 볼륨에는 없다. 장애 전환 컨트롤러가 Ceph 차단을 먼저 하는 이유다. MySQL PVC도 같은 StorageClass를 쓰므로 같은 조건이다.

### 컨트롤러 초기판이 Ceph 키를 노출했다
처음에는 키를 `--key` 인자로 넘겨서 dry-run 로그에 키가 찍혔다. 키링 파일 방식으로 고치고 키를 새로 발급했다.

### 도메인을 만든 직후 일부 기기에서 이름이 안 풀린다
레코드를 만들기 전에 조회한 "없음" 결과가 기기의 DNS 캐시에 남아 있었다. 해당 기기의 DNS 캐시를 비우면 풀린다.

### 공유기 DNS가 새 이름에 NXDOMAIN을 간헐적으로 준다
공인 DNS와 내부 DNS는 항상 정상이었지만 공유기(`10.5.5.1`)에 물으면 15번 중 6번이 NXDOMAIN이었다. 내부 DNS는 모르는 이름을 공유기로 넘기고 그 NXDOMAIN을 30초 캐시해서, 접속이 구간 단위로 끊겼다. 오래된 도메인은 영향이 없었다. 내부 DNS가 이 이름을 직접 답하게 해서 해결했다. 공유기 DNS를 직접 쓰는 기기는 여전히 영향을 받을 수 있다.

### DDNS 갱신 목록에 없는 이름은 공인 IP가 바뀌면 따라가지 못한다
`gitlab.example.com`은 고정 A 레코드다. 집 공인 IP를 주기적으로 갱신하는 DDNS 호스트 목록에 넣지 않으면, 공인 IP가 바뀔 때 이 이름만 옛 IP를 가리킨다. 목록에 추가하거나 DDNS가 관리하는 이름으로의 CNAME으로 바꿔야 한다.

### 출발지 IP로 접속을 제한할 수 없다
ingress-nginx 서비스가 `externalTrafficPolicy: Cluster`라서 요청의 출발지가 노드 대역으로 바뀐다. 허용 IP 목록을 걸 수 없다. `Local`로 바꾸면 되지만 다른 사이트에도 영향이 있어 하지 않았다.

## 검증 명령

```bash
# 파드와 배치 노드 확인
kubectl -n gitlab get pods -o wide

# PVC와 Service(VIP) 확인
kubectl -n gitlab get pvc,svc

# 인증서 발급 상태 확인
kubectl -n gitlab get certificate

# HTTPS 응답과 인증서 발급자 확인
curl -s -o /dev/null -w "%{http_code} verify=%{ssl_verify_result}\n" https://gitlab.example.com/users/sign_in

# 회원가입이 꺼져 있는지 확인
kubectl -n gitlab exec deploy/gitlab -- gitlab-rails runner 'puts ApplicationSetting.current.signup_enabled'

# SSH 포트 열림 확인
nc -z -w3 10.5.5.55 22

# 내부 DNS가 공인 도메인을 사설 IP로 직접 답하는지 확인
dig +short gitlab.example.com @10.5.5.2

# 백업을 수동으로 한 번 실행해 본다
kubectl -n gitlab create job --from=cronjob/gitlab-backup backup-manual-1

# 장애 전환 컨트롤러 3개 상태 확인
kubectl -n node-failover get pods -o wide

# 컨트롤러 로그 확인
kubectl -n node-failover logs ds/node-failover --tail=20
```

## 검증 이력

- 2026-10-17: GitLab 배포. 최초 기동 후 헬스체크 404 문제를 발견해 해결했다. 사설 CA(Vault PKI)로 HTTPS를 구성하고 `homelab-root-ca` 신뢰 시 200, 미신뢰 시 거부되는 것을 확인했다.
- 2026-10-18: 백업 CronJob을 수동 실행해 앱 백업 tar(약 820KB)와 설정 압축본이 NAS에 생기는 것을 확인했다. 복원 리허설은 하지 않았다.
- 2026-10-18: 공인 도메인으로 전환해 Let's Encrypt 인증서 발급, HTTPS 200, 검증 통과를 확인했다. 회원가입을 비활성화했다.
- 2026-10-18: 공인 도메인 접속이 간헐적으로 끊기는 문제를 조사했다. 공유기 DNS의 간헐적 NXDOMAIN이 원인임을 확인하고 내부 DNS에 직접 등록했다. 등록 후 A 25/25 정상, 시스템 리졸버 경유 접속 40/40 성공을 확인했다.
- 2026-10-18: 장애 전환 컨트롤러를 3노드에 배포했다. 정상 노드(chan09)를 장애 노드로 가정하는 시험 모드(DRY_RUN)에서 RBD 3개 인식, 살아있는 watcher 인식, 실행될 명령 출력을 확인했고 실제 상태는 바뀌지 않았다. 노드를 실제로 내린 장애 테스트는 하지 않았다.
- 2026-10-18: Runner를 설치하고 별도 저장소의 dbt 파이프라인을 돌렸다. 작업마다 `gitlab-runner` 네임스페이스에 파드가 생겼다가 사라지는 것과 파이프라인 두 단계(`validate`, `deploy`)가 성공하는 것을 확인했다. 작업 이미지에 `git`이 없어 `dbt debug`의 의존성 점검이 실패한 적이 있다. 연결 점검만 하도록 옵션을 바꿔 해결했다.

---

[← 이전: LLM 서빙](12-llm-serving.md)
