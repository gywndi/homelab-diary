# MySQL을 Ceph RBD로 재배포

Stage 1(chan08/chan09 keepalived 페일오버)을 대체했다. 이제 단일 mysqld가 k8s Deployment + Ceph RBD PVC 위에서 돈다. 스토리지 배경은 [Ceph 스토리지](07-1-ceph-storage.md) 참고.

## 목적

Stage 1은 MySQL 자체 복제(semi-sync)로 데이터를 이중화했다. 이제는 Ceph가 데이터를 3벌 복제해준다. MySQL이 직접 복제를 관리할 필요가 없어졌다. 인스턴스도 하나로 줄었다. 노드가 죽으면 k8s가 다른 노드로 재스케줄하면 끝이다.

## 설계 결정

- **"shared-disk failover cluster" 패턴으로 전환.** mysqld는 하나만 띄운다. 데이터 내구성은 Ceph 3-replica가 담당한다. 노드가 죽으면 k8s가 파드를 다른 노드로 재스케줄한다. RBD PVC는 그대로 새 파드를 따라간다.
- **RBD의 exclusive-lock이 핵심 안전장치다.** 한 순간에 한 클라이언트만 쓸 수 있게 강제하는 잠금이다. 두 노드가 동시에 같은 datadir을 잡으려 해도 락에 막혀 실패한다. split-brain(두 곳이 동시에 자신이 주인이라 믿고 쓰다 데이터가 어긋나는 사고)을 막아준다.
- **Deployment(replicas=1) + Recreate 전략.** 단일 인스턴스라 StatefulSet은 과하다. Recreate는 기존 파드가 완전히 종료된 뒤에만 새 파드를 띄운다. RWO(ReadWriteOnce — 한 번에 파드 하나만 마운트 가능) PVC 핸드오프에 이 순서가 필요하다.
- **기존 VIP(`10.5.5.4`)를 재사용.** 새 k8s Service를 MetalLB로 같은 IP에 노출했다. 애플리케이션은 접속 주소를 바꿀 필요가 없다.

## 스크립트 목록 (이름 순)

### MySQL 백업
- 설명: `/data`를 비우기 전 chan08(source)에서 전체 백업한다. chan09(replica)는 복제를 끊고 폐기할 예정이라 별도 백업이 필요 없다.
- 스크립트: [`05-backup-mysql.sh`](../scripts/07-ceph-storage/05-backup-mysql.sh)
```bash
# --single-transaction: InnoDB 테이블을 잠그지 않고 일관된 스냅샷으로 덤프
mysqldump --all-databases --single-transaction --routines --triggers --events | gzip > all-databases.sql.gz

gzip -t all-databases.sql.gz && echo "gzip 무결성 OK"
```

### MySQL datadir 임시 이전
- 설명: chan08에서 datadir을 `/data`에서 `/home`(nvme, OS 디스크)으로 먼저 옮긴다. `/data`는 곧 Ceph OSD로 전환될 디스크다. 이렇게 하면 Ceph 구축을 기다리지 않고 `/data`를 바로 비울 수 있다. 최종적으로는 k8s RBD PVC로 한 번 더 옮긴다.
- 스크립트: [`06-relocate-mysql-datadir.sh`](../scripts/07-ceph-storage/06-relocate-mysql-datadir.sh)
```bash
SRC="/data/mysql"
DST="/home/mysql"

# AppArmor 로컬 오버라이드에 새 경로 허용 추가(Ubuntu MySQL 패키지가 datadir 경로를 화이트리스트로 제한)
cat >> /etc/apparmor.d/local/usr.sbin.mysqld <<EOF
${DST}/ r,
${DST}/** rwk,
EOF
apparmor_parser -r /etc/apparmor.d/usr.sbin.mysqld

systemctl stop mysql

# rsync -a로 소유권/권한 보존하며 물리 복사. 원본 /data/mysql은 삭제하지 않고 남겨둔다 — 이후 디스크 wipe 때 같이 없어진다.
rsync -a "${SRC}/" "${DST}/"

sed -i "s|^datadir\s*=.*|datadir = ${DST}|" /etc/mysql/mysql.conf.d/zz-datadir.cnf
systemctl start mysql
```

### 데이터 디스크 wipe
- 설명: `/data`를 Ceph OSD용 raw 상태로 전환한다. 되돌릴 수 없는 작업이다. 데이터가 이미 다른 곳으로 이전/백업되어 있어야 한다.
- 스크립트: [`07-wipe-data-disk.sh`](../scripts/07-ceph-storage/07-wipe-data-disk.sh)
```bash
DEV=$(findmnt -n -o SOURCE /data)

umount /data
wipefs -a "$DEV"
sed -i '\|[[:space:]]/data[[:space:]]|d' /etc/fstab
```

### MySQL k8s 리소스(네임스페이스/설정/PVC) 생성
- 설명: RBD PVC(30Gi, `rook-ceph-block`) 기반으로 MySQL을 재배포하기 위한 네임스페이스/ConfigMap/PVC를 만든다.
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
  storageClassName: rook-ceph-block
  resources: {requests: {storage: 30Gi}}
```

### MySQL 데이터를 RBD PVC로 이전
- 설명: 기존 호스트(`/home/mysql`)의 데이터를 RBD PVC로 옮긴다. mysqld를 정지시킨다. 이 시점부터 새 파드 기동까지가 다운타임 구간이다.
- 스크립트: [`09-mysql-migrate-data.sh`](../scripts/07-ceph-storage/09-mysql-migrate-data.sh)
```bash
# PVC만 마운트하는 임시 loader 파드로 tar 스트림 복사
kubectl -n mysql wait --for=condition=Ready pod/mysql-data-loader --timeout=120s

sudo systemctl stop mysql

tar -C /home/mysql -cf - . | kubectl exec -i -n mysql mysql-data-loader -- tar -C /var/lib/mysql -xf -

# 공식 mysql 이미지 규격(999:999)으로 소유권 설정
kubectl -n mysql exec mysql-data-loader -- chown -R 999:999 /var/lib/mysql
kubectl -n mysql delete pod mysql-data-loader --wait=true
```

### MySQL Deployment 배포
- 설명: Deployment(replicas=1) + Recreate 전략 + 명시적 PVC로 구성한다.
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

### MySQL VIP를 MetalLB로 컷오버
- 설명: 기존 keepalived VIP(`10.5.5.4`)를 k8s Service(MetalLB)로 이관한다. 파드 정상 기동과 데이터 확인이 끝난 뒤에 실행한다.
- 스크립트: [`11-mysql-vip-cutover.sh`](../scripts/07-ceph-storage/11-mysql-vip-cutover.sh)
```bash
# 양쪽 노드에서 keepalived 중지(VIP 회수)
ssh 10.5.5.8 'sudo systemctl stop keepalived'
ssh 10.5.5.9 'sudo systemctl stop keepalived'

# IPAddressPool/L2Advertisement로 같은 VIP(10.5.5.4)를 MetalLB에 등록(ingress와 같은 패턴)

# externalTrafficPolicy: Local이 필수다. Cluster(기본값)면 트래픽 받은 노드와 파드 노드가 다를 때
# kube-proxy가 SNAT을 해서 클라이언트 IP가 바뀐다. host@'10.5.5.%' 기반 grant가 그 IP를 못 알아본다.
# (단일 replica라 Local로 바꿔도 가용성엔 영향 없다.)
kubectl -n mysql patch svc mysql -p '{"spec":{"type":"LoadBalancer","externalTrafficPolicy":"Local"}}'
```

## 알려진 이슈

### datadir을 옮겨도 binlog/AppArmor 설정은 안 따라온다
별도 튜닝 설정에 `log_bin`이 절대경로로 하드코딩돼 있으면 datadir을 바꿔도 계속 옛 경로에 쓴다. datadir과 별개인 절대경로 항목(`log_bin`, `innodb_undo_directory` 등)을 따로 확인해야 한다. Ubuntu MySQL 패키지의 AppArmor 로컬 오버라이드(`/etc/apparmor.d/local/usr.sbin.mysqld`)도 새 경로를 추가해야 한다. 안 하면 mysqld가 파일 접근을 거부당하며 죽는다.

### semi-sync 복제 잔재가 첫 커밋을 10초 가까이 멈추게 했다
물리 복사로 datadir을 옮길 때 `rpl_semi_sync_source_enabled=1`이 persisted variable(서버를 재시작해도 유지되는 MySQL 설정값)로 그대로 딸려왔다. 레플리카는 이미 폐기했는데, 소스는 여전히 레플리카의 ack(수신 확인)를 기다리는 상태였다. 첫 트랜잭션에서 10초 타임아웃 후 자동으로 async(비동기)로 전환됐다. 하지만 파드가 재시작될 때마다 재발할 위험이 있어서 `UNINSTALL PLUGIN` + `RESET PERSIST`로 완전히 제거했다.

### externalTrafficPolicy 기본값 때문에 호스트 기반 인증이 깨졌다(가장 심각했던 문제)
`Cluster`(기본값) 정책에서는 트래픽을 받은 노드와 파드가 있는 노드가 다르면 kube-proxy가 SNAT(요청의 출발지 IP를 바꿔치기하는 것)을 한다. 그러면 MySQL이 보는 클라이언트 IP가 호스트 기반 grant(`user@'10.5.5.%'`)와 안 맞는 pod-CIDR 주소로 바뀐다. 실서비스 DB 라우트가 전부 500 에러를 냈다. `externalTrafficPolicy: Local`로 바꿔서 해결했다(단일 replica라 가용성 영향 없음). **호스트 기반 MySQL 인증 + MetalLB LoadBalancer 조합에서는 `Local`이 필수다.**

## 성능

같은 `sysbench oltp_read_write`(8 threads, 40만 행)로 튜닝 전후를 재측정했다.

| 지표 | 튜닝 전 | 튜닝 후 | 개선 |
|---|---|---|---|
| TPS(초당 처리한 트랜잭션 수) | 125.29 | 190.98 | **+52%** |
| 평균 지연 | 63.80ms | 41.87ms | **-34%** |
| 95th 지연(가장 느린 5%를 뺀 체감 최대 지연) | 137.35ms | 99.33ms | -28% |

튜닝 내용은 `innodb_flush_log_at_trx_commit=2`(위 ConfigMap 참고) + semi-sync 잔재 제거다. 1GbE 위에서 매 커밋마다 fsync를 강제하면 RBD 3-replica 전체 ack를 매번 기다려야 한다. 이 병목의 근본 원인(1GbE 네트워크)은 [Ceph 벤치마크](07-2-ceph-storage-bmt.md) 참고.
