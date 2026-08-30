# StarRocks 베어메탈 배포 (KVM VM 3대)

[← 이전: KVM 하이퍼바이저 인프라](06-1-kvm.md) · [다음: Ceph 스토리지 →](07-1-ceph-storage.md)

k8s가 아니라 systemd로 직접 관리하는 진짜 베어메탈(VM) StarRocks 클러스터. [`06-1-kvm.md`](06-1-kvm.md)로 만든 VM 3대(`starrocks-vm1/2/3`, 노드당 하나씩)에 FE 1개(vm1) + BE 3개(전 VM)를 올렸다.

## 목적

k8s 위에서 돌리던([`08-1-starrocks-analytics.md`](08-1-starrocks-analytics.md)) 것과 달리, 컨테이너·오케스트레이터 없이 systemd 유닛만으로 뜨는 StarRocks를 실제로 구성·운영해본다. 성능 비교가 목적이 아니다 — VM인 이상 물리 배포보다 빠를 이유가 없다. 목적은 **구성과 유지관리 경험 자체**다. 컨테이너 이미지 뒤에 숨어있던 것들(자바 설치, 바이너리 압축 해제, conf 파일 직접 편집, systemd 유닛 작성, 프로세스 재시작 절차)을 전부 직접 다뤄본다.

## 대상 VM

| VM | 물리 노드 | IP | 역할 |
|---|---|---|---|
| starrocks-vm1 | chan08 | 10.5.5.52 | FE + BE |
| starrocks-vm2 | chan09 | 10.5.5.53 | BE |
| starrocks-vm3 | llm001 | 10.5.5.54 | BE |

## 설계 결정

- **FE는 1개만.** 3-FE HA(Follower 쿼럼)는 [concepts/03-starrocks.md](../concepts/03-starrocks.md#fe-확장-follower-vs-observer)에서 다룬 대로 구성 복잡도가 늘어난다(헬퍼 노드 지정, BDBJE 쿼럼 관리). 이 클러스터의 목적은 "베어메탈 운영 경험"이지 FE 이중화 실습이 아니라서, 가장 흔한 소규모 배포 형태(단일 FE + 여러 BE)로 시작했다. FE 이중화가 필요해지면 `ALTER SYSTEM ADD FOLLOWER`로 언제든 확장 가능하다.
- **VM1은 FE와 BE를 겸한다.** VM 3대뿐이라 FE 전용 VM을 따로 빼면 BE가 2개로 줄어든다. 소규모 클러스터에서는 흔한 절충이다 — k8s 버전에서도 초기엔 FE가 CN과 같은 노드에 있었다([`08-2-starrocks-analytics-bmt.md`](08-2-starrocks-analytics-bmt.md)의 FE 배치 실험 참고, 거기서는 오히려 이 배치가 병목이었다 — 4GB VM 3대라는 훨씬 작은 규모라 지금은 문제 삼지 않는다).
- **컨테이너 이미지 대신 공식 바이너리 tarball.** k8s 배포는 `starrocks/fe-ubuntu` 같은 도커 이미지를 썼지만, 베어메탈에서는 `releases.starrocks.io`에서 받는 `StarRocks-<버전>-ubuntu-amd64.tar.gz`를 직접 풀어서 쓴다. 이 편이 "진짜 베어메탈"에 가깝다 — 컨테이너 런타임 자체가 없다.
- **systemd로 직접 관리, `--daemon` 안 씀.** StarRocks의 `start_fe.sh`/`start_be.sh`는 자체 데몬화(`--daemon`) 옵션이 있지만, systemd가 프로세스를 직접 추적하게 하려고 포그라운드로 띄운다(`Type=simple`). `--daemon`으로 이중 데몬화하면 systemd가 실제 프로세스를 잃어버려 재시작/상태 확인이 꼬인다.
- **JVM 힙을 4GB VM에 맞춰 축소.** FE 기본값(`-Xmx8192m`)은 VM 전체 메모리보다 크다. `1536m`으로 낮췄다 — 데이터가 거의 없는 실습 클러스터라 이 정도로 충분하다.

## 스크립트 목록 (이름 순)

### FE 설치
- 설명: Java 설치 + StarRocks 바이너리 배포 + fe.conf 조정 + systemd 유닛 등록까지 한 번에. vm1에서만 실행.
- 스크립트: [`04-install-starrocks-fe.sh`](../scripts/06-kvm/04-install-starrocks-fe.sh)
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

### BE 설치
- 설명: 위와 동일한 패턴으로 BE를 설치한다. VM 3대 전부(vm1도 포함 — FE와 BE 겸용).
- 스크립트: [`05-install-starrocks-be.sh`](../scripts/06-kvm/05-install-starrocks-be.sh)
```bash
sudo ./05-install-starrocks-be.sh 10.5.5.52   # vm1
sudo ./05-install-starrocks-be.sh 10.5.5.53   # vm2
sudo ./05-install-starrocks-be.sh 10.5.5.54   # vm3
```

### BE를 FE에 등록
- 설명: BE 프로세스가 떠 있어도 FE가 알아야 클러스터의 일부가 된다. IP:heartbeat_service_port(9050) 형식으로 등록한다.
- 스크립트: 없음, mysql 클라이언트로 직접 실행
```sql
-- FE에 접속 (mysql -h 10.5.5.52 -P 9030 -u root)
ALTER SYSTEM ADD BACKEND '10.5.5.52:9050';
ALTER SYSTEM ADD BACKEND '10.5.5.53:9050';
ALTER SYSTEM ADD BACKEND '10.5.5.54:9050';
```
k8s 버전은 headless Service의 고정 hostname으로 등록했지만([`08-4-starrocks-ops.md`](08-4-starrocks-ops.md)), 여기서는 그냥 고정 IP를 쓴다 — VM은 파드처럼 재시작마다 새 IP를 받지 않고, cloud-init으로 IP 자체를 고정해뒀기 때문에 굳이 DNS를 개입시킬 이유가 없다.

## 검증 명령

```bash
# BE 3개 전부 Alive인지
mysql -h 10.5.5.52 -P 9030 -u root -e "SHOW BACKENDS\G" | grep -E 'HostName|Alive'

# 실제 쓰기/조회 + 3-replica 분산 확인
mysql -h 10.5.5.52 -P 9030 -u root -e "
CREATE DATABASE IF NOT EXISTS demo;
CREATE TABLE IF NOT EXISTS demo.t1 (id BIGINT, name VARCHAR(50))
  DUPLICATE KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 3 PROPERTIES('replication_num'='3');
INSERT INTO demo.t1 VALUES (1,'a'),(2,'b'),(3,'c');
SELECT * FROM demo.t1 ORDER BY id;
SHOW TABLET FROM demo.t1;   -- 각 tablet마다 BackendId 3개(10001/10002/10003)가 다 나와야 정상
"

# systemd 레벨 상태 (각 VM에서)
sudo systemctl status starrocks-fe   # vm1만
sudo systemctl status starrocks-be   # 전부
```

## 운영 명령 (일상)

k8s 버전([`08-4-starrocks-ops.md`](08-4-starrocks-ops.md))의 SQL 명령은 그대로 쓸 수 있다 — 차이는 "재시작을 어떻게 시키는가"뿐이다.

```bash
# 재시작 (systemd가 대신해준다 — kubectl rollout restart 대신)
sudo systemctl restart starrocks-fe   # vm1
sudo systemctl restart starrocks-be   # 해당 VM

# 로그 (kubectl logs 대신 systemd 저널 + StarRocks 자체 로그 둘 다 확인)
sudo journalctl -u starrocks-fe -f
tail -f /opt/starrocks/fe/log/fe.log

# 부팅 시 자동 시작 여부
sudo systemctl is-enabled starrocks-fe starrocks-be
```

## 알려진 이슈

### JVM 기본 힙(-Xmx8192m)이 VM 전체 메모리보다 크다
공식 tarball의 `fe.conf` 기본값은 물리 서버 기준(넉넉한 메모리 가정)이다. 이 4GB VM에 그대로 적용하면 JVM이 뜨자마자 메모리 부족으로 죽거나, 뜨더라도 시스템 전체가 스왑에 시달린다. **컨테이너 이미지를 쓸 때는 k8s가 resource limit으로 이 문제를 강제로 막아줬지만, 베어메탈에서는 conf 파일을 직접 열어서 확인하는 수밖에 없다** — 이게 컨테이너 배포와 베어메탈 배포의 실질적 차이 중 하나다.

### 클러스터당 유일한 FE가 재시작되는 동안은 아무 쿼리도 안 된다
BE는 여러 개라 죽어도 나머지가 버텨주지만, FE가 1개뿐이면 그 순간 클러스터 전체가 멎는다. `systemctl restart starrocks-fe`는 짧으면 수 초, 길면 수십 초 걸릴 수 있다 — 운영 중 재시작이 필요하면 이 다운타임을 감안해야 한다. FE를 여러 개로 늘리는 게 정답이지만(위 "설계 결정" 참고), 이 클러스터에서는 의도적으로 안 했다.

---

[← 이전: KVM 하이퍼바이저 인프라](06-1-kvm.md) · [다음: Ceph 스토리지 →](07-1-ceph-storage.md)
