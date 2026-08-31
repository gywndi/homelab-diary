# StarRocks 베어메탈 구축 (KVM VM)

[← 이전: StarRocks 분석 엔진](08-1-starrocks-analytics.md) · [다음: StarRocks 벤치마크 →](08-3-starrocks-analytics-bmt.md)

k8s가 아니라 systemd로 직접 관리하는 진짜 베어메탈(VM) StarRocks 클러스터. [`06-kvm.md`](06-kvm.md)로 만든 VM 3대(`starrocks-vm1/2/3`, 노드당 하나씩) 위에 두 가지 클러스터를 독립적으로 올렸다 — shared-nothing(FE+BE, 로컬 디스크)과 shared-data(FE+CN, Ceph RGW).

## 목적

k8s 위에서 돌리던([`08-1-starrocks-analytics.md`](08-1-starrocks-analytics.md)) 것과 달리, 컨테이너·오케스트레이터 없이 systemd 유닛만으로 뜨는 StarRocks를 실제로 구성·운영해본다. 성능 비교가 목적이 아니다 — VM인 이상 물리 배포보다 빠를 이유가 없다. 목적은 **구성과 유지관리 경험 자체**다. 컨테이너 이미지 뒤에 숨어있던 것들(자바 설치, 바이너리 압축 해제, conf 파일 직접 편집, systemd 유닛 작성, 프로세스 재시작 절차)을 전부 직접 다뤄본다. shared-data(CN) 클러스터를 추가한 이유도 같다 — k8s에서는 이미 다뤄본 구성이지만, 베어메탈에서는 오브젝트 스토리지 자격증명을 conf 파일에 직접 박아 넣는 것부터 다시 손으로 해봐야 한다.

## 대상 VM

| VM | 물리 노드 | IP | shared-nothing 역할 | shared-data 역할 |
|---|---|---|---|---|
| starrocks-vm1 | chan08 | 10.5.5.52 | FE + BE | FE2(shared-data) + CN |
| starrocks-vm2 | chan09 | 10.5.5.53 | BE | - |
| starrocks-vm3 | llm001 | 10.5.5.54 | BE | - |

## 설계 결정

- **FE는 클러스터마다 1개만.** 3-FE HA(Follower 쿼럼)는 [concepts/03-starrocks.md](../concepts/03-starrocks.md#fe-확장-follower-vs-observer)에서 다룬 대로 구성 복잡도가 늘어난다(헬퍼 노드 지정, BDBJE 쿼럼 관리). 이 클러스터의 목적은 "베어메탈 운영 경험"이지 FE 이중화 실습이 아니라서, 가장 흔한 소규모 배포 형태(단일 FE + 여러 BE/CN)로 시작했다. FE 이중화가 필요해지면 `ALTER SYSTEM ADD FOLLOWER`로 언제든 확장 가능하다.
- **VM1이 4가지 역할(FE, BE, FE2, CN)을 전부 겸한다.** VM 3대뿐이라 역할별로 VM을 따로 빼면 구성이 훨씬 커진다. 소규모 클러스터에서는 흔한 절충이다 — k8s 버전에서도 초기엔 FE가 CN과 같은 노드에 있었다([`08-3-starrocks-analytics-bmt.md`](08-3-starrocks-analytics-bmt.md)의 FE 배치 실험 참고, 거기서는 오히려 이 배치가 병목이었다 — 4GB VM 3대라는 훨씬 작은 규모라 지금은 문제 삼지 않는다).
- **shared-data는 완전히 별도 FE(FE2)로 띄운다.** `run_mode`(shared-data인지 아닌지)는 FE를 처음 띄울 때 정해지는 클러스터 전역 설정이고, 이후 못 바꾼다. 기존 shared-nothing FE를 건드리지 않고, 포트를 전부 분리한 두 번째 FE 인스턴스(`/opt/starrocks-sd/fe`, query port 9031)를 같은 VM1에 새로 설치했다.
- **CN 디렉터리는 공식 tarball에 없다 — BE 디렉터리를 복사해서 만든다.** CN은 BE와 바이너리가 완전히 같고, `be/bin/start_cn.sh`와 `be/conf/cn.conf`로 이미 포함돼 있다. 기존 BE(로컬 디스크, shared-nothing용) 인스턴스와 conf/포트가 섞이지 않도록 별도 디렉터리(`/opt/starrocks-sd/cn`)로 복사해서 쓴다.
- **컨테이너 이미지 대신 공식 바이너리 tarball.** k8s 배포는 `starrocks/fe-ubuntu` 같은 도커 이미지를 썼지만, 베어메탈에서는 `releases.starrocks.io`에서 받는 `StarRocks-<버전>-ubuntu-amd64.tar.gz`를 직접 풀어서 쓴다. 이 편이 "진짜 베어메탈"에 가깝다 — 컨테이너 런타임 자체가 없다.
- **systemd로 직접 관리, `--daemon` 안 씀.** StarRocks의 `start_fe.sh`/`start_be.sh`/`start_cn.sh`는 자체 데몬화(`--daemon`) 옵션이 있지만, systemd가 프로세스를 직접 추적하게 하려고 포그라운드로 띄운다(`Type=simple`). `--daemon`으로 이중 데몬화하면 systemd가 실제 프로세스를 잃어버려 재시작/상태 확인이 꼬인다.
- **JVM 힙을 4GB VM에 맞춰 축소.** FE 기본값(`-Xmx8192m`)은 VM 전체 메모리보다 크다. shared-nothing FE는 `1536m`, VM1에 같이 뜨는 shared-data FE2는 `1024m`로 낮췄다 — 데이터가 거의 없는 실습 클러스터라 이 정도로 충분하다.
- **RGW 자격증명은 git에 올리지 않는다.** k8s 버전은 Secret으로 숨겼지만([`08-1-starrocks-analytics.md`](08-1-starrocks-analytics.md) 설계 결정 참고), 베어메탈은 conf 파일에 평문으로 들어갈 수밖에 없다 — 대신 스크립트가 RGW 유저를 그때그때 만들어 키를 화면에 출력하고, 그 값을 다음 스크립트의 인자로 직접 넘기는 방식으로 git에는 절대 안 남긴다.

## 스크립트 목록 (이름 순)

### FE 설치 (shared-nothing)
- 설명: Java 설치 + StarRocks 바이너리 배포 + fe.conf 조정 + systemd 유닛 등록까지 한 번에. vm1에서만 실행.
- 스크립트: [`04-install-starrocks-fe.sh`](../scripts/08-starrocks/04-install-starrocks-fe.sh)
```bash
sudo ./04-install-starrocks-fe.sh 10.5.5.52
```
핵심 부분:
```bash
# 힙을 4GB VM에 맞춰 축소 + 이 노드 IP로 바인딩 고정
sed -i 's/-Xmx8192m/-Xmx1536m/' /opt/starrocks/fe/conf/fe.conf
echo "priority_networks = 10.5.5.52/32" >> /opt/starrocks/fe/conf/fe.conf

# systemd로 등록 (foreground 모드, --daemon 안 씀)
cat > /etc/systemd/system/starrocks-fe.service <<'EOF'
[Service]
Type=simple
User=chan
WorkingDirectory=/opt/starrocks/fe
ExecStart=/opt/starrocks/fe/bin/start_fe.sh
ExecStop=/opt/starrocks/fe/bin/stop_fe.sh
Restart=on-failure
EOF
systemctl enable --now starrocks-fe
```

### BE 설치 (shared-nothing)
- 설명: 위와 동일한 패턴으로 BE를 설치한다. VM 3대 전부(vm1도 포함 — FE와 BE 겸용).
- 스크립트: [`05-install-starrocks-be.sh`](../scripts/08-starrocks/05-install-starrocks-be.sh)
```bash
sudo ./05-install-starrocks-be.sh 10.5.5.52   # vm1
sudo ./05-install-starrocks-be.sh 10.5.5.53   # vm2
sudo ./05-install-starrocks-be.sh 10.5.5.54   # vm3
```

### shared-data RGW 유저/버킷 생성
- 설명: shared-data 클러스터 전용 RGW 유저와 버킷을 만든다. chan08(cephadm 호스트)에서 실행.
- 스크립트: [`06-create-shared-data-rgw-user-and-bucket.sh`](../scripts/08-starrocks/06-create-shared-data-rgw-user-and-bucket.sh)
```bash
./06-create-shared-data-rgw-user-and-bucket.sh
```
출력된 `ACCESS_KEY`/`SECRET_KEY`는 <RGW 유저 생성 시 매번 새로 발급되는 값이라 문서에 고정 기록하지 않는다> — 다음 단계(07번)에 인자로 그대로 넘긴다.

### shared-data FE 설치
- 설명: 두 번째 FE(`run_mode=shared_data`)를 vm1에 추가로 설치한다. 기존 FE와 완전히 독립된 인스턴스.
- 스크립트: [`07-install-shared-data-fe.sh`](../scripts/08-starrocks/07-install-shared-data-fe.sh)
```bash
sudo ./07-install-shared-data-fe.sh 10.5.5.52 <ACCESS_KEY> <SECRET_KEY>
```
핵심 부분:
```bash
# 기존 FE(shared-nothing)와 포트 전부 분리 + shared_data 설정
cat >> /opt/starrocks-sd/fe/conf/fe.conf <<EOF
http_port = 8031
rpc_port = 9021
query_port = 9031
edit_log_port = 9011
run_mode = shared_data
cloud_native_storage_type = S3
aws_s3_path = baremetal-starrocks-storage
aws_s3_endpoint = http://ceph.home:7480
aws_s3_access_key = <ACCESS_KEY>
aws_s3_secret_key = <SECRET_KEY>
EOF
```

### CN 설치
- 설명: CN(Compute Node)을 이 VM에 설치한다. BE와 바이너리가 같고 conf/실행 스크립트만 다르다.
- 스크립트: [`08-install-cn.sh`](../scripts/08-starrocks/08-install-cn.sh)
```bash
sudo ./08-install-cn.sh 10.5.5.52
```
핵심 부분:
```bash
# 바이너리 다운로드 후 be/ 디렉터리를 cn/으로 복사 (기존 BE 인스턴스와 분리)
tar -xzf /tmp/starrocks-cn.tar.gz -C /tmp/starrocks-cn-extract --strip-components=1
cp -r /tmp/starrocks-cn-extract/be /opt/starrocks-sd/cn

# cn.conf 조정 (기존 BE와 포트 전부 분리)
cat >> /opt/starrocks-sd/cn/conf/cn.conf <<EOF
be_port = 9061
brpc_port = 8061
heartbeat_service_port = 9051
starlet_port = 9071
priority_networks = 10.5.5.52/32
EOF
```

### BE/CN을 FE에 등록
- 설명: 프로세스가 떠 있어도 각 FE가 알아야 클러스터의 일부가 된다. shared-nothing BE는 `ADD BACKEND`, shared-data CN은 `ADD COMPUTE NODE`.
- 스크립트: 없음, mysql 클라이언트로 직접 실행
```sql
-- shared-nothing FE에 접속 (mysql -h 10.5.5.52 -P 9030 -u root)
ALTER SYSTEM ADD BACKEND '10.5.5.52:9050';
ALTER SYSTEM ADD BACKEND '10.5.5.53:9050';
ALTER SYSTEM ADD BACKEND '10.5.5.54:9050';

-- shared-data FE2에 접속 (mysql -h 10.5.5.52 -P 9031 -u root)
ALTER SYSTEM ADD COMPUTE NODE '10.5.5.52:9051';
```
k8s 버전은 headless Service의 고정 hostname으로 등록했지만([`08-5-starrocks-ops.md`](08-5-starrocks-ops.md)), 여기서는 그냥 고정 IP를 쓴다 — VM은 파드처럼 재시작마다 새 IP를 받지 않고, cloud-init으로 IP 자체를 고정해뒀기 때문에 굳이 DNS를 개입시킬 이유가 없다.

## 검증 명령

```bash
# shared-nothing: BE 3개 전부 Alive인지
mysql -h 10.5.5.52 -P 9030 -u root -e "SHOW BACKENDS\G" | grep -E 'HostName|Alive'

# shared-nothing: 실제 쓰기/조회 + 3-replica 분산 확인
mysql -h 10.5.5.52 -P 9030 -u root -e "
CREATE DATABASE IF NOT EXISTS demo;
CREATE TABLE IF NOT EXISTS demo.t1 (id BIGINT, name VARCHAR(50))
  DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 3 PROPERTIES('replication_num'='3');
INSERT INTO demo.t1 VALUES (1,'a'),(2,'b'),(3,'c');
SELECT * FROM demo.t1 ORDER BY id;
SHOW TABLET FROM demo.t1;   -- 각 tablet마다 BackendId 3개(10001/10002/10003)가 다 나와야 정상
"

# shared-data: CN Alive 확인
mysql -h 10.5.5.52 -P 9031 -u root -e "SHOW COMPUTE NODES\G" | grep -E 'IP|Alive|HasStoragePath'

# shared-data: RGW에 실제로 쓰고 읽히는지 (storage_volume이 cloud-native인지 확인)
mysql -h 10.5.5.52 -P 9031 -u root -e "
CREATE DATABASE IF NOT EXISTS demo;
CREATE TABLE IF NOT EXISTS demo.t1 (id INT) DISTRIBUTED BY HASH(id) PROPERTIES('replication_num'='1');
INSERT INTO demo.t1 VALUES (1),(2),(3);
SELECT * FROM demo.t1;
SHOW CREATE TABLE demo.t1;   -- storage_volume = 'builtin_storage_volume' 나와야 정상
"

# systemd 레벨 상태 (각 VM에서)
sudo systemctl status starrocks-fe      # vm1만 (shared-nothing FE)
sudo systemctl status starrocks-be      # 전부 (shared-nothing BE)
sudo systemctl status starrocks-sd-fe   # vm1만 (shared-data FE2)
sudo systemctl status starrocks-cn      # vm1만 (CN)
```

## 운영 명령 (일상)

k8s 버전([`08-5-starrocks-ops.md`](08-5-starrocks-ops.md))의 SQL 명령은 그대로 쓸 수 있다 — 차이는 "재시작을 어떻게 시키는가"뿐이다.

```bash
# 재시작 (systemd가 대신해준다 — kubectl rollout restart 대신)
sudo systemctl restart starrocks-fe      # vm1 (shared-nothing FE)
sudo systemctl restart starrocks-be      # 해당 VM (shared-nothing BE)
sudo systemctl restart starrocks-sd-fe   # vm1 (shared-data FE2)
sudo systemctl restart starrocks-cn      # vm1 (CN)

# 로그 (kubectl logs 대신 systemd 저널 + StarRocks 자체 로그 둘 다 확인)
sudo journalctl -u starrocks-fe -f
tail -f /opt/starrocks/fe/log/fe.log

# 부팅 시 자동 시작 여부
sudo systemctl is-enabled starrocks-fe starrocks-be starrocks-sd-fe starrocks-cn
```

## 알려진 이슈

### JVM 기본 힙(-Xmx8192m)이 VM 전체 메모리보다 크다
공식 tarball의 `fe.conf` 기본값(물리 서버 기준)을 4GB VM에 그대로 쓰면 OOM으로 죽거나 시스템 전체가 스왑에 시달린다. 컨테이너 배포는 k8s resource limit이 강제하지만, 베어메탈은 conf 파일을 직접 확인해야 한다.

### 클러스터당 유일한 FE가 재시작되는 동안은 아무 쿼리도 안 된다
BE/CN은 여러 개라 죽어도 나머지가 버텨주지만, FE가 1개뿐이면 재시작하는 수 초~수십 초 동안 클러스터 전체가 멎는다. FE를 여러 개로 늘리면 해결되지만(위 "설계 결정" 참고), 이 클러스터에서는 의도적으로 안 했다.

### 이미 실행 중인 인스턴스 디렉터리를 `cp -r`로 복제하면 안 된다
실행된 적 있는 인스턴스 디렉터리(BE 등)를 복사해 새 인스턴스(CN 등)를 만들면 `bin/*.pid`와 `meta`/`storage`의 실행 상태까지 같이 복사돼 등록 충돌이 난다. 새 인스턴스는 항상 실행된 적 없는 새 tarball 압축 해제본에서 만든다(`08-install-cn.sh`가 매번 새로 받는 이유).

### `tablet_create_timeout_second`를 60으로 올려도 첫 테이블 생성이 타임아웃날 수 있다
CN 콜드스타트 직후(RGW와의 첫 연결 지연)엔 기본값(10초)의 6배인 60초로도 첫 `CREATE TABLE`이 타임아웃 날 수 있다. 워밍업 후 재시도하거나, 콜드스타트 직후라면 타임아웃을 120초 이상으로 잡을 것.

## 검증 이력

- 2026-08-31: shared-nothing(FE+BE 3대) 3-replica 쓰기/조회 확인, shared-data(FE2+CN) `SHOW CREATE TABLE`로 `builtin_storage_volume` 확인, insert/select 정상 동작 확인.

---

[← 이전: StarRocks 분석 엔진](08-1-starrocks-analytics.md) · [다음: StarRocks 벤치마크 →](08-3-starrocks-analytics-bmt.md)
