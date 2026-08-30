# MySQL을 Ceph RBD로 재배포

[Stage 1(chan08/chan09 keepalived 페일오버)](03-1-mysql-ha.md)을 대체했다. 이제 단일 mysqld가 k8s Deployment + Ceph RBD PVC 위에서 돈다. 스토리지 배경은 [Ceph 스토리지](07-1-ceph-storage.md) 참고.

> VIP는 이 문서에 적힌 `10.5.5.4`에서 2026-08-29에 옮겨졌다(애플리케이션 VIP 대역 정책 적용). 지금은 IP를 직접 쓰지 않고 **`mysql.k8s.home`** 도메인으로 접속한다 — [내부 DNS](09-internal-dns.md) 참고. VIP가 다시 바뀌어도 이 도메인만 갱신하면 된다.
>
> 2026-08-30에 스토리지 백엔드가 Rook에서 cephadm(베어메탈)으로 바뀌었다 — 자세한 배경은 [Ceph 스토리지](07-1-ceph-storage.md) 참고. `StorageClass`만 `rook-ceph-block`에서 `ceph-csi-rbd`로 바뀌었고, Deployment/PVC 구조와 애플리케이션 접속 방식(`mysql.k8s.home`)은 그대로다.

## 목적

Stage 1은 MySQL 자체 복제(semi-sync)로 데이터를 이중화했다. 이제는 Ceph가 데이터를 3벌 복제해준다. MySQL이 직접 복제를 관리할 필요가 없어졌다. 인스턴스도 하나로 줄었다. 노드가 죽으면 k8s가 다른 노드로 재스케줄하면 끝이다.

## 설계 결정

- **"shared-disk failover cluster" 패턴으로 전환.** mysqld는 하나만 띄운다. 데이터 내구성은 Ceph 3-replica가 담당한다. 노드가 죽으면 k8s가 파드를 다른 노드로 재스케줄한다. RBD PVC는 그대로 새 파드를 따라간다.
- **RBD의 exclusive-lock이 핵심 안전장치다.** 한 순간에 한 클라이언트만 쓸 수 있게 강제하는 잠금이다. 두 노드가 동시에 같은 datadir을 잡으려 해도 락에 막혀 실패한다. split-brain(두 곳이 동시에 자신이 주인이라 믿고 쓰다 데이터가 어긋나는 사고)을 막아준다.
- **Deployment(replicas=1) + Recreate 전략.** 단일 인스턴스라 StatefulSet은 과하다. Recreate는 기존 파드가 완전히 종료된 뒤에만 새 파드를 띄운다. RWO(ReadWriteOnce — 한 번에 파드 하나만 마운트 가능) PVC 핸드오프에 이 순서가 필요하다.
- **기존 VIP(`10.5.5.4`)를 재사용.** 새 k8s Service를 MetalLB로 같은 IP에 노출했다. 애플리케이션은 접속 주소를 바꿀 필요가 없다.

## 스크립트 목록 (이름 순)

### 네임스페이스 생성
- 설명: MySQL 전용 네임스페이스를 만든다(모든 하위 리소스가 이 안에 들어간다).
```bash
kubectl create namespace mysql
```

### MySQL k8s 리소스(설정/PVC) 생성
- 설명: RBD PVC(30Gi, `ceph-csi-rbd`) 기반으로 MySQL을 재배포하기 위한 ConfigMap/PVC를 만든다.
- 스크립트: [`08-mysql-configmap-pvc.yaml`](../scripts/07-ceph-storage/08-mysql-configmap-pvc.yaml)
```yaml
apiVersion: v1
kind: ConfigMap
metadata: {name: mysql-config, namespace: mysql}
data:
  custom.cnf: |
    [mysqld]
    innodb_buffer_pool_size = 2G
    bind-address = 0.0.0.0
    # 1GbE 위 Ceph RBD라 매 커밋 fsync가 네트워크 왕복을 유발한다. 1초 단위로 묶어 커밋 지연을 줄인다.
    # mysqld 크래시엔 안전하다. OS 자체가 크래시하면 최근 1초분을 잃을 수 있다.
    innodb_flush_log_at_trx_commit = 2
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: mysql-data, namespace: mysql}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ceph-csi-rbd
  resources: {requests: {storage: 30Gi}}
```
```bash
kubectl apply -f 08-mysql-configmap-pvc.yaml
```

### MySQL Deployment 배포
- 설명: Deployment(replicas=1) + Recreate 전략 + 명시적 PVC로 구성한다. 최초 배포 시에는 PVC가 비어있는 상태로 뜨므로, 실제 데이터는 아래 "최초 마이그레이션 기록"의 절차로 채운다 — 이 파드가 처음부터 빈 데이터로 기동해도 정상이다.
- 스크립트: [`10-mysql-deploy.yaml`](../scripts/07-ceph-storage/10-mysql-deploy.yaml)
```yaml
apiVersion: apps/v1
kind: Deployment
metadata: {name: mysql, namespace: mysql}
spec:
  replicas: 1
  strategy: {type: Recreate}
  selector: {matchLabels: {app: mysql}}
  template:
    metadata: {labels: {app: mysql}}
    spec:
      containers:
        - name: mysql
          image: mysql:8.0.46
          volumeMounts:
            - {name: data, mountPath: /var/lib/mysql}
            - {name: config, mountPath: /etc/mysql/conf.d}
      volumes:
        - {name: data, persistentVolumeClaim: {claimName: mysql-data}}
        - {name: config, configMap: {name: mysql-config}}
```
```bash
kubectl apply -f 10-mysql-deploy.yaml
kubectl -n mysql rollout status deployment/mysql --timeout=180s
```

### Service(MetalLB VIP) 노출
- 설명: 기존 VIP를 MetalLB LoadBalancer Service로 재현한다. 전용 IPAddressPool(`mysql-pool`, 주소 1개짜리)을 따로 둬서 이 Service만 그 IP를 배타적으로 받게 했다 — [ingress](04-1-ingress.md#vip-대역-등록)처럼 공유 풀에 `loadBalancerIPs` annotation으로 못 박는 대신, "이 풀엔 이 IP 하나뿐"이라는 방식으로 같은 효과를 냈다. `externalTrafficPolicy: Local`이 필수인 이유는 아래 "알려진 이슈" 참고. 별도 스크립트 파일 없이 인터랙티브로 적용했다 — 재현 시 아래 매니페스트 그대로 사용.
```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata: {name: mysql-pool, namespace: metallb-system}
spec:
  addresses: ["10.5.5.51/32"]
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata: {name: mysql-l2, namespace: metallb-system}
spec:
  ipAddressPools: [mysql-pool]
---
apiVersion: v1
kind: Service
metadata: {name: mysql, namespace: mysql}
spec:
  type: LoadBalancer
  externalTrafficPolicy: Local
  selector: {app: mysql}
  ports:
    - {port: 3306, targetPort: 3306}
```
```bash
kubectl apply -f mysql-svc.yaml
kubectl -n mysql get svc mysql   # EXTERNAL-IP가 10.5.5.51(mysql.k8s.home)로 뜨는지 확인
```

## 최초 마이그레이션 기록 (2026-08-27, 스크립트는 삭제됨)

호스트 네이티브 MySQL(Stage 1)을 Ceph RBD로 옮긴 최초 1회성 절차다. 그 호스트 네이티브 인스턴스 자체가 이제 없어서 다시 실행할 일이 없다 — 스크립트 파일은 지웠고, 실제로 무엇을 했는지만 기록으로 남긴다.

1. **백업**: chan08(source)에서 `mysqldump --all-databases --single-transaction --routines --triggers --events | gzip > all-databases.sql.gz`. chan09(replica)는 복제를 끊고 폐기할 예정이라 별도 백업 없음.
2. **datadir 임시 이전**: `/data`(곧 Ceph OSD로 전환될 디스크)를 비우려고, datadir을 `/home`(OS 디스크)으로 먼저 옮겼다. AppArmor 로컬 오버라이드에 새 경로를 허용 추가해야 했다(안 하면 mysqld가 파일 접근을 거부당함). `rsync -a`로 물리 복사 후 `datadir` 설정 변경, mysqld 재기동.
3. **데이터 디스크 wipe**: `/data` 마운트 해제 → `wipefs -a`로 파일시스템 시그니처 제거 → fstab에서 항목 삭제. Ceph OSD가 이 디스크를 raw로 넘겨받을 수 있게 하는 되돌릴 수 없는 단계라, 앞 단계에서 데이터가 안전히 옮겨졌는지 먼저 확인했다.
4. **RBD PVC로 데이터 이전**: PVC만 마운트하는 임시 loader 파드(`ubuntu:24.04`, `sleep 3600`)를 띄우고, mysqld를 정지한 뒤 `tar -C /home/mysql -cf - . | kubectl exec -i ... -- tar -C /var/lib/mysql -xf -`로 스트림 복사. 공식 mysql 이미지 규격(999:999)으로 소유권 맞춘 뒤 loader 파드 삭제. 이 시점부터 새 파드 기동까지가 다운타임 구간이었다.
5. **VIP 컷오버**: 양쪽 노드에서 keepalived를 정지해 기존 VIP(`10.5.5.4`)를 회수하고, 같은 IP로 MetalLB Service(`type: LoadBalancer`)를 등록했다. `externalTrafficPolicy: Local`이 필수였다 — 아래 "알려진 이슈" 참고.

## 알려진 이슈

### datadir을 옮겨도 binlog/AppArmor 설정은 안 따라온다
별도 튜닝 설정에 `log_bin`이 절대경로로 하드코딩돼 있으면 datadir을 바꿔도 계속 옛 경로에 쓴다. datadir과 별개인 절대경로 항목(`log_bin`, `innodb_undo_directory` 등)을 따로 확인해야 한다. Ubuntu MySQL 패키지의 AppArmor 로컬 오버라이드(`/etc/apparmor.d/local/usr.sbin.mysqld`)도 새 경로를 추가해야 한다. 안 하면 mysqld가 파일 접근을 거부당하며 죽는다.

### semi-sync 복제 잔재가 첫 커밋을 10초 가까이 멈추게 했다
물리 복사로 datadir을 옮길 때 `rpl_semi_sync_source_enabled=1`이 persisted variable(서버를 재시작해도 유지되는 MySQL 설정값)로 그대로 딸려왔다. 레플리카는 이미 폐기했는데, 소스는 여전히 레플리카의 ack(수신 확인)를 기다리는 상태였다. 첫 트랜잭션에서 10초 타임아웃 후 자동으로 async(비동기)로 전환됐다. 하지만 파드가 재시작될 때마다 재발할 위험이 있어서 `UNINSTALL PLUGIN` + `RESET PERSIST`로 완전히 제거했다.

### externalTrafficPolicy 기본값 때문에 호스트 기반 인증이 깨졌다(가장 심각했던 문제)
`Cluster`(기본값) 정책에서는 트래픽을 받은 노드와 파드가 있는 노드가 다르면 kube-proxy가 SNAT(요청의 출발지 IP를 바꿔치기하는 것)을 한다. 그러면 MySQL이 보는 클라이언트 IP가 호스트 기반 grant(`user@'10.5.5.%'`)와 안 맞는 pod-CIDR 주소로 바뀐다. 실서비스 DB 라우트가 전부 500 에러를 냈다. `externalTrafficPolicy: Local`로 바꿔서 해결했다(단일 replica라 가용성 영향 없음). **호스트 기반 MySQL 인증 + MetalLB LoadBalancer 조합에서는 `Local`이 필수다.**

## 검증 명령

```bash
# 파드/PVC/Service가 전부 정상인지 한눈에
kubectl -n mysql get pods,pvc,svc -o wide

# 파드 안에서 직접 접속 (root는 auth_socket 인증이라 로컬에서만 됨 — 네트워크 접속엔 못 씀)
kubectl -n mysql exec deploy/mysql -- mysql -e "SELECT 1;"

# VIP/도메인까지 실제로 도달하는지 (실제 계정 없이도 네트워크+서버 응답을 확인하는 방법 —
# "Access denied"가 나오면 인증만 실패한 것이고, DNS 해석부터 externalTrafficPolicy: Local
# 라우팅까지는 전부 정상이라는 뜻이다. "connect ... failed"/타임아웃이면 그 앞단이 문제)
kubectl run mysql-connect-test --rm -i --restart=Never --image=mysql:8.0.46 -- \
  mysqladmin ping -h mysql.k8s.home -u probe

# 실제 애플리케이션 계정으로 접속 확인 (호스트 기반 grant라 10.5.5.0/24 대역의 실제 호스트에서 실행해야 함 —
# k8s 파드 안에서 실행하면 출발지 IP가 파드 서브넷(10.244.0.0/16)이라 grant와 안 맞아 무조건 거부된다)
mysql -h mysql.k8s.home -u <애플리케이션 계정> -p -e "SELECT 1;"
```

## 성능

같은 `sysbench oltp_read_write`(8 threads, 40만 행)로 튜닝 전후를 재측정했다.

| 지표 | 튜닝 전 | 튜닝 후 | 개선 |
|---|---|---|---|
| TPS(초당 처리한 트랜잭션 수) | 125.29 | 190.98 | **+52%** |
| 평균 지연 | 63.80ms | 41.87ms | **-34%** |
| 95th 지연(가장 느린 5%를 뺀 체감 최대 지연) | 137.35ms | 99.33ms | -28% |

튜닝 내용은 `innodb_flush_log_at_trx_commit=2`(위 ConfigMap 참고) + semi-sync 잔재 제거다. 1GbE 위에서 매 커밋마다 fsync를 강제하면 RBD 3-replica 전체 ack를 매번 기다려야 한다. 이 병목의 근본 원인(1GbE 네트워크)은 [Ceph 벤치마크](07-2-ceph-storage-bmt.md) 참고.

---

[← 이전: MySQL active/standby](03-1-mysql-ha.md) · [다음: Ingress + 인증서 →](04-1-ingress.md)
