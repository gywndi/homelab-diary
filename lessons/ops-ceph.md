# Ceph 운영 명령 모음

[`07-1-ceph-storage.md`](07-1-ceph-storage.md)로 구축한 3노드(chan08/chan09/llm001) cephadm 베어메탈 클러스터를 평소에 들여다보고 조작할 때 쓰는 명령들. 구축 절차가 아니라 "상태를 확인하고, 용량/유저/버킷을 관리하고, 뭔가 이상할 때 원인을 좁히는" 용도. Ceph CLI는 호스트에 직접 설치돼 있지 않다(우분투 24.04엔 공식 저장소가 없어서) — 전부 `cephadm shell --` 접두사로 실행하고, chan08(관리 노드)에서 실행한다. 아래 명령들의 systemctl/LVM/네트워크 기초는 [리눅스 기본 상식](ops-linux-basics.md) 참고.

## 클러스터 상태

```bash
# 전체 헬스 (HEALTH_OK/WARN/ERR)
cephadm shell -- ceph -s

# 헬스 WARN/ERR일 때 구체적인 원인
cephadm shell -- ceph health detail

# OSD별 노드 배치 + up/down/in/out 상태
cephadm shell -- ceph osd tree

# OSD별 사용률 + PG(Placement Group, 데이터를 나눠 OSD에 분산 배치하는 단위) 분산 균형도
cephadm shell -- ceph osd df

# 데몬(mon/mgr/osd/rgw) 배치 현황 — 어느 노드에 뭐가 떠있는지
cephadm shell -- ceph orch ps

# 클러스터에 속한 호스트 목록
cephadm shell -- ceph orch host ls

# 전체 용량 요약
cephadm shell -- ceph df
```

## 풀(pool) 관리

```bash
# 풀 목록 + 사용량
cephadm shell -- ceph osd pool ls detail
cephadm shell -- ceph df detail

# 특정 풀의 replica 설정 확인/변경
cephadm shell -- ceph osd pool get rbd-pool size
cephadm shell -- ceph osd pool get rbd-pool min_size
cephadm shell -- ceph osd pool set rbd-pool size 3

# PG 개수 확인 (너무 적으면 분산이 불균형, 너무 많으면 메모리/CPU 낭비)
cephadm shell -- ceph osd pool get rbd-pool pg_num
```
PG 수를 바꾸는 작업(`pg_num`/`pgp_num`)은 클러스터 전체 리밸런싱을 유발해서 트래픽이 큰 시간대는 피하는 게 안전하다. 지금 규모(32 PG, 데이터 적음)에서는 아직 손댈 필요가 없었다.

## RBD(블록) 운영

```bash
# 이 풀에 있는 이미지(볼륨) 목록
cephadm shell -- rbd ls rbd-pool

# 이미지 상세 (크기, 어느 클라이언트가 배타 잠금을 쥐고 있는지)
cephadm shell -- rbd info rbd-pool/<image>
cephadm shell -- rbd status rbd-pool/<image>

# k8s PVC가 만든 이미지 이름은 ceph-csi가 자동 생성(csi-vol-<uuid> 형식) —
# 어떤 PVC가 어떤 이미지인지 매칭하려면 k8s 쪽에서 먼저 확인
kubectl get pv -o custom-columns=NAME:.metadata.name,VOLUME:.spec.csi.volumeHandle,CLAIM:.spec.claimRef.name
```

## RGW(오브젝트) — 유저/버킷 관리

`radosgw-admin`은 버킷 **생성**은 지원하지 않는다(S3 API로만 가능, [`07-1-ceph-storage.md`](07-1-ceph-storage.md#애플리케이션에서-rgw-쓰기boto3-s3-api) 참고) — 유저/키/쿼터 관리는 이 명령으로 한다.

```bash
# 유저 생성 (access/secret key 자동 발급)
cephadm shell -- radosgw-admin user create --uid=<이름> --display-name="<표시 이름>"

# 이미 있는 유저 정보(키 포함) 조회 — user create를 이미 만든 유저에 다시 실행하면 에러라 이걸로 대체
cephadm shell -- radosgw-admin user info --uid=<이름>

# 유저 목록
cephadm shell -- radosgw-admin user list

# 유저별 버킷 목록 + 사용량
cephadm shell -- radosgw-admin bucket list --uid=<이름>
cephadm shell -- radosgw-admin bucket stats --bucket=<버킷>

# 유저 쿼터 설정 (용량 폭주 방지 — 기본은 무제한)
cephadm shell -- radosgw-admin quota set --uid=<이름> --quota-scope=user --max-size=100G
cephadm shell -- radosgw-admin quota enable --uid=<이름> --quota-scope=user

# 유저 삭제 (버킷까지 통째로 지우려면 --purge-data)
cephadm shell -- radosgw-admin user rm --uid=<이름> --purge-data
```
버킷을 새로 만들 때는 [`07-1-ceph-storage.md`의 boto3 예시](07-1-ceph-storage.md#애플리케이션에서-rgw-쓰기boto3-s3-api)나 [`08-starrocks/00-create-rgw-user-and-bucket.sh`](../scripts/08-starrocks/00-create-rgw-user-and-bucket.sh)의 AWS SigV2 수동 서명 `curl` 패턴을 참고. RGW 엔드포인트는 `http://ceph.home:7480`(내부망 전용 아님, keepalived VIP로 어디서든 접근 가능).

```bash
# S3 API로 실제 오브젝트가 몇 개 쌓였는지 빠르게 확인하고 싶을 때 (버킷 stats보다 직접적)
cephadm shell -- radosgw-admin bucket stats --bucket=<버킷> | grep -E 'num_objects|size_kb_actual'
```

## OSD 운영

```bash
# 새 디스크/파티션을 OSD로 추가 (LVM으로 한 겹 감싸야 함 — raw 파티션은 못 받음)
sudo pvcreate /dev/sdX1 && sudo vgcreate ceph-osd-vg /dev/sdX1 && sudo lvcreate -l 100%FREE -n osd-data ceph-osd-vg
cephadm shell -- ceph orch daemon add osd "<노드>:/dev/ceph-osd-vg/osd-data"

# 특정 OSD를 안전하게 빼기 (교체/은퇴 시 — 먼저 데이터를 다른 OSD로 옮기고 나서 제거)
cephadm shell -- ceph orch osd rm <OSD ID> --replace   # 리밸런싱 진행 상황은 ceph -s에서 확인
cephadm shell -- ceph orch osd rm status                # 진행 중인 제거 작업 목록

# OSD 하나가 죽었을 때 (up=false, in=true로 보임) 재시작
cephadm shell -- ceph orch daemon restart osd.<ID>
```

## RGW VIP (keepalived)

```bash
# 지금 RGW VIP(10.5.5.4, ceph.home)를 누가 들고 있는지 (각 노드에서 실행)
ip -4 addr show | grep 10.5.5.4

# keepalived 상태/로그
sudo systemctl status keepalived
sudo journalctl -u keepalived --since '10 min ago'

# RGW 자체가 로컬에서 살아있는지 (헬스체크가 보는 것과 동일)
curl -sf -o /dev/null -w '%{http_code}\n' http://127.0.0.1:7480/
```

## 데몬 재시작/전체 클러스터 재기동

```bash
# 특정 데몬만 재시작 (mon/mgr/osd/rgw 전부 동일한 방식)
cephadm shell -- ceph orch daemon restart <데몬 이름>   # 예: mon.chan08, rgw.starrocks-store.chan09...

# 특정 서비스(같은 종류 전체)를 한 번에 재시작
cephadm shell -- ceph orch restart rgw

# 노드 자체를 재부팅해야 할 때 — 먼저 그 노드의 mon이 쿼럼에서 안전하게 빠질 수 있는지 확인
cephadm shell -- ceph -s   # HEALTH_OK면 mon 3개 중 1개가 잠깐 빠져도 쿼럼(과반 2/3) 유지됨
```

## 대시보드

```bash
# 대시보드 URL/포트 확인
cephadm shell -- ceph mgr services

# 관리자 비밀번호를 잊었으면 재설정 (부트스트랩 시 랜덤 생성됨)
cephadm shell -- ceph dashboard ac-user-set-password admin -i <새 비밀번호가 담긴 파일>
```
기본적으로 `https://<mgr이 떠있는 노드>:8443`. mgr은 활성/대기 인스턴스가 있어서 어느 노드가 지금 활성인지는 `ceph orch ps`의 `mgr` 행에서 STATUS가 `running`인 것을 본다.

## 흔한 장애 체크리스트

- **`ceph -s`가 HEALTH_WARN**: `ceph health detail`로 구체 원인부터 본다 — OSD 하나 down, PG degraded, 클럭 스큐(시간 동기화 어긋남) 등 원인별로 대응이 다르다.
- **k8s PVC가 `Pending`인데 Ceph는 HEALTH_OK**: ceph-csi 플러그인 파드(`kubectl -n ceph-csi get pods`)가 떠있는지, `client.k8s` cephx 유저의 권한(`ceph auth get client.k8s`)이 대상 풀에 맞는지 확인.
- **krbd 매핑이 `secret too big`으로 실패**: 신규 클러스터의 기본 인증 cipher가 커널 krbd와 안 맞는 문제 — `ceph mon set auth_allowed_ciphers "aes, aes256k"` 필요(부트스트랩 스크립트에 이미 포함되지만, 클러스터를 재부트스트랩한 경우 놓치기 쉽다). [`07-1-ceph-storage.md`의 관련 알려진 이슈](07-1-ceph-storage.md#알려진-이슈) 참고.
- **RGW VIP에 접속이 안 됨**: 3노드 전부에서 keepalived가 죽어있을 수 있다 — 위 "RGW VIP" 섹션으로 어느 노드가 들고 있는지부터 확인. RGW 데몬 자체가 죽은 경우(`ceph orch ps`에서 rgw 행 확인)와 구분할 것.
- **버킷 생성이 반복 실패**: `radosgw-admin`으로는 버킷을 못 만든다 — S3 API(boto3/curl SigV2)로만 가능. 이미 있는 버킷에 재시도하면 `BucketAlreadyOwnedByYou`(같은 유저라 무해) 또는 `BucketAlreadyExists`(다른 유저 소유, 이름 충돌) 에러가 정상적으로 난다.
- **디스크를 재분할했더니 그 위 데이터가 사라짐**: OSD 파티션 옆에 나눠둔 XFS 파티션(`/mnt/local-data`) 위의 데이터는 Ceph가 보호해주지 않는다 — 파티션을 다시 나누면 그 안의 애플리케이션 데이터(예: StarRocks shared-nothing BE)도 같이 없어진다.
