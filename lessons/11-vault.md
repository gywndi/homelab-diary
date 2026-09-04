# Vault (시크릿 관리)

[← 이전: NAS 연동](10-nas-storage.md)

AWS Secrets Manager 같은 시크릿 관리 시스템을 자체 호스팅해본다. k8s StatefulSet으로 3개 파드, Raft Integrated Storage로 쿼럼을 구성했다. 개념(Raft 쿼럼, unseal, 동적 시크릿)은 [concepts/04-vault.md](../concepts/04-vault.md) 참고.

## 목적

정적 KV 저장뿐 아니라, 요청 시점에 짧은 수명 자격증명을 즉석 생성하는 동적 시크릿(dynamic secrets)까지 실제로 구성·검증한다. mon(Ceph)/etcd(k8s)와 같은 Raft/쿼럼 계열이지만, unseal이라는 Vault만의 운영 개념이 재시작마다 반복된다는 것도 실제로 재현해서 확인한다.

## 대상

k8s StatefulSet으로 3노드(chan08/chan09/llm001) 전부에 파드 하나씩 배치된다 — 물리 노드를 직접 다루는 스크립트는 없다.

| 파드 | 역할 | 스토리지 |
|---|---|---|
| vault-0 | 초기 leader | PVC 2Gi(`ceph-csi-rbd`) |
| vault-1 | follower | PVC 2Gi(`ceph-csi-rbd`) |
| vault-2 | follower | PVC 2Gi(`ceph-csi-rbd`) |

## 스크립트 목록 (이름 순)

### MySQL 동적 시크릿 구성
- 설명: database secrets engine을 MySQL에 연결하고, 요청마다 새 계정을 만들어주는 `readonly` 역할을 정의한다. Vault 전용 MySQL 관리 계정(`CREATE USER` + 해당 스키마 `GRANT` 권한)도 이 스크립트가 같이 만든다.
- 스크립트: [`03-configure-mysql-dynamic-secrets.sh`](../scripts/11-vault/03-configure-mysql-dynamic-secrets.sh)
```bash
./03-configure-mysql-dynamic-secrets.sh <root token> <MySQL vault 계정 비밀번호>
```
핵심 부분:
```bash
# database secrets engine 활성화 + MySQL 연결
vault secrets enable database
vault write database/config/mysql-demo \
  plugin_name=mysql-database-plugin \
  connection_url="{{username}}:{{password}}@tcp(mysql.mysql.svc.cluster.local:3306)/" \
  allowed_roles="readonly" \
  username="vault" \
  password="<MySQL vault 계정 비밀번호>"

# readonly 역할: 요청마다 이 SQL로 새 계정을 만든다 (기본 5분, 최대 1시간 TTL)
vault write database/roles/readonly \
  db_name=mysql-demo \
  creation_statements="CREATE USER '{{name}}'@'%' IDENTIFIED BY '{{password}}'; GRANT SELECT ON vault_demo.* TO '{{name}}'@'%';" \
  default_ttl="5m" \
  max_ttl="1h"
```

### Vault 배포
- 설명: 네임스페이스, 설정(ConfigMap), 헤드리스 Service(Raft 피어 통신, 8201) + 클라이언트 API Service(8200), StatefulSet(3 replica)을 만든다. TLS는 비활성(`tls_disable = 1`) — 테스트 목적으로 범위를 좁혔다(아래 "알려진 이슈" 참고).
- 스크립트: [`01-deploy-vault.sh`](../scripts/11-vault/01-deploy-vault.sh)
```bash
./01-deploy-vault.sh
```
핵심 부분:
```hcl
ui = true
disable_mlock = false
listener "tcp" {
  address     = "[::]:8200"
  tls_disable = 1
}
storage "raft" {
  path = "/vault/data"
  retry_join {
    leader_api_addr = "http://vault-0.vault-internal.vault.svc.cluster.local:8200"
  }
  retry_join {
    leader_api_addr = "http://vault-1.vault-internal.vault.svc.cluster.local:8200"
  }
  retry_join {
    leader_api_addr = "http://vault-2.vault-internal.vault.svc.cluster.local:8200"
  }
}
```
파드는 노드(`vault-N`)마다 자기 자신의 API/클러스터 주소를 알려야 해서, 컨테이너 시작 시점에 `POD_NAME`(downward API)으로 조립한다:
```bash
export VAULT_API_ADDR="http://${POD_NAME}.vault-internal.vault.svc.cluster.local:8200"
export VAULT_CLUSTER_ADDR="http://${POD_NAME}.vault-internal.vault.svc.cluster.local:8201"
exec vault server -config=/vault/config/vault.hcl
```
StatefulSet은 파드를 순서대로(vault-0 Ready여야 vault-1 생성) 만든다 — readiness probe가 `/v1/sys/health`를 보기 때문에, **vault-0을 init+unseal해야 vault-1이 뜬다.**

### 초기화 + unseal
- 설명: 최초 1회 `vault operator init`으로 unseal key 5개(임계값 3)와 root token을 발급받고, 파드가 하나씩 뜨는 순서에 맞춰 3개 전부 unseal한다. 학습/테스트 편의상 키를 로컬 파일에 모아 저장한다 — 실제 운영이라면 조각마다 서로 다른 사람에게 나눠주고 한 곳에 모아두지 않는다(그러면 Shamir 분산의 의미가 사라짐).
- 스크립트: [`02-init-unseal.sh`](../scripts/11-vault/02-init-unseal.sh)
```bash
./02-init-unseal.sh /path/to/vault-init.json
```
핵심 부분:
```bash
# 최초 초기화 — 이 출력(특히 root_token, unseal_keys_b64)은 다시 못 받는다
vault operator init -key-shares=5 -key-threshold=3 -format=json

# unseal은 조각 3개(임계값)를 순서대로 제출
vault operator unseal <조각1>
vault operator unseal <조각2>
vault operator unseal <조각3>
```

## 설계 결정

- **Helm 대신 raw manifest.** 이 저장소의 다른 애드온(MetalLB, cert-manager)과 같은 방식 — `kubectl apply`로 직접 작성한 YAML을 쓴다. 명령 하나하나가 뭘 하는지 그대로 드러나는 쪽을 우선했다.
- **Consul 대신 Raft Integrated Storage.** 별도 스토리지 백엔드 컴포넌트 없이 Vault 프로세스만으로 쿼럼이 완성된다 — mon(Ceph)/etcd(k8s)에 이미 익숙한 패턴이라 새 컴포넌트를 하나 더 추가할 이유가 없었다.
- **PVC는 ceph-csi-rbd.** 파드마다 독립된 볼륨이 필요한(RWO) 구조라 이미 있는 StorageClass를 그대로 재사용했다.
- **수동 unseal.** auto-unseal(외부 KMS)을 걸려면 클라우드 KMS가 없는 이 환경에선 별도 Vault(Transit 엔진 전용)를 하나 더 세워야 하는데, 그 Vault는 또 누가 unseal하냐는 재귀적 문제가 남는다([concepts/04-vault.md](../concepts/04-vault.md) 참고). 지금은 이 구조적 한계를 그대로 두고 수동 unseal로 운영한다.
- **동적 시크릿 대상은 MySQL.** 이미 이 클러스터에 있는 워크로드라 새 인프라를 안 늘리고도 실제 자격증명 발급·회수를 검증할 수 있었다. Vault 전용 MySQL 관리 계정(`vault`@`%`)은 `CREATE USER`만 전역으로, 나머지는 `vault_demo` 스키마로 좁혔다.

## 알려진 이슈

### Vault 1.20부터 `disable_mlock`을 명시해야 한다
설정 안 하면 기동 자체가 실패한다(`ERROR: disable_mlock must be configured`). `disable_mlock = false`로 명시하고, 컨테이너에 `IPC_LOCK` capability를 줘야 실제로 mlock이 동작한다.

### StatefulSet 파드 생성 순서와 unseal 순서가 맞물려 있다
readiness probe가 sealed 상태를 실패로 보므로, vault-0을 unseal하기 전엔 vault-1이 아예 안 뜬다. `01-deploy-vault.sh` 실행 직후엔 vault-0만 보이는 게 정상이다.

## 검증 명령

```bash
# 파드 상태 (3/3 Ready여야 정상)
kubectl -n vault get pods

# Raft 쿼럼 확인 (leader 1 + voter follower 2)
kubectl -n vault exec vault-0 -- env VAULT_TOKEN=<root token> vault operator raft list-peers

# 동적 자격증명 발급 (호출마다 MySQL에 새 계정이 실제로 생성됨)
kubectl -n vault exec vault-0 -- env VAULT_TOKEN=<root token> vault read database/creds/readonly
```

## 검증 이력

2026-09-04 전체 검증 완료:
1. 3파드 배포 → init(5 shares/threshold 3) → 순서대로 unseal, `raft list-peers`로 leader 1 + voter follower 2 확인(vault-2는 처음엔 non-voter로 조인했다가 autopilot이 자동으로 voter 승격)
2. KV v2 활성화 후 `secret/demo/app`에 쓰고 그대로 읽히는 것 확인
3. **unseal 재현**: vault-2 파드를 강제 삭제 → 재기동된 파드가 다시 `Sealed: true`로 뜨는 것 확인 → 3개 키로 다시 unseal해서 정상화
4. **동적 시크릿 end-to-end**: `database/creds/readonly`로 발급받은 자격증명으로 실제 MySQL 접속 성공(`vault_demo.items` SELECT), 권한 밖 스키마(`mysql`, `information_schema`) 접근은 거부됨 확인. `vault lease revoke`로 강제 회수 후 같은 자격증명으로 재접속 시도 시 `Access denied` 확인(Vault가 실제로 MySQL `DROP USER`까지 수행함을 증명)

---

[← 이전: NAS 연동](10-nas-storage.md)
