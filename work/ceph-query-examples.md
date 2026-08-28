# Ceph 사용 예시

> 이 문서는 초안이다. 검증까지 끝나면 `lessons/`로 옮겨 다듬는다. 배경 설명은 [소개](ceph-intro.md), 이 명령들의 실측 결과는 [BMT](ceph-bmt.md) 참고.

이번 검증 과정에서 실제로 실행해본 명령 모음이다. 대부분 `rook-ceph-tools` 파드(toolbox) 안에서 실행한다:

```bash
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- <명령>
```

## 클러스터 상태 확인

```bash
ceph -s                    # 전체 상태 요약(HEALTH_OK/WARN, mon/osd 수, PG 상태)
ceph df                    # 풀별 사용량/오브젝트 수
ceph osd df                # OSD별 사용률, PG 분산 균형도(VAR/STDDEV)
ceph osd perf               # OSD별 commit/apply 지연(ms) — 디스크 자체가 병목인지 확인용
ceph osd tree               # OSD 계층 구조(노드/디스크 매핑)
```

## OSD 하나씩 살아있는지 확인 (방화벽/네트워크 문제 디버깅)

`rados`/`radosgw-admin` 명령이 에러 없이 그냥 멈출 때, 특정 OSD 하나만 응답이 없는 건 아닌지 개별로 확인하는 방법:

```bash
ceph tell osd.0 version
ceph tell osd.1 version
ceph tell osd.2 version
```

## OSD를 안전하게 클러스터에서 빼기 (디스크 재구성 전)

```bash
ceph osd out osd.3                          # 데이터 재분산(remap) 시작
ceph -s                                      # active+clean 될 때까지 대기(misplaced만 있으면 무해)
kubectl -n rook-ceph delete deployment rook-ceph-osd-3
ceph osd purge osd.3 --yes-i-really-mean-it  # 카탈로그에서 완전 제거
```

## BlueStore 레이블 직접 확인 (디스크 재구성 트러블슈팅)

```bash
ceph-bluestore-tool show-label --dev /dev/sda1
```
`locations: [...]` 필드로 실제 레이블이 어느 오프셋에 저장돼 있는지 확인할 수 있다 — 디스크를 재분할했는데 Rook이 "기존 OSD 확장"으로 오판할 때 이걸로 원인을 잡았다([설치](ceph-install.md) "디스크 재분할" 섹션 참고).

## 성능 측정

```bash
# 쓰기 벤치마크 (4MB 오브젝트, 16 스레드, 30초)
rados bench -p rbd-pool 30 write --no-cleanup

# 읽기 벤치마크 (순차/랜덤)
rados bench -p rbd-pool 30 seq
rados bench -p rbd-pool 30 rand

# 네트워크 링크 자체 확인 (Ceph와 무관하게 노드 간 대역폭 확인)
# 한쪽에서: iperf3 -s
# 다른쪽에서: iperf3 -c <서버 IP>
```

## RBD(블록) 관련

```bash
rbd pool init rbd-pool                    # 풀을 RBD 용도로 초기화
rbd create rbd-pool/my-image --size 10G   # 이미지 생성
rbd ls rbd-pool                           # 이미지 목록
rbd info rbd-pool/my-image                # 이미지 상세(exclusive-lock 포함 feature 목록)
rbd du rbd-pool/my-image                  # 실사용량(thin provisioning이라 size와 다름)
```

k8s에서는 이 계층을 CSI 드라이버가 대신 처리한다 — PVC를 만들면 자동으로 RBD 이미지가 생성/attach된다.

## RGW(오브젝트) 관련 — radosgw-admin

```bash
# 유저 생성 (버킷 생성은 지원 안 함 — S3 API로만 가능)
radosgw-admin user create --uid=demo-app --display-name="Demo App" --rgw-realm=starrocks-store

# 유저 정보/키 확인
radosgw-admin user info --uid=demo-app --rgw-realm=starrocks-store

# 버킷 통계
radosgw-admin bucket stats --bucket=<bucket-name>

# 버킷 목록 (zone/realm 설정에 따라 빈 결과가 나올 수 있음 — bucket stats로 직접 확인하는 게 더 안정적)
radosgw-admin bucket list
```

## RGW 버킷 생성 — 수동 서명한 S3 API PUT (awscli 없이)

radosgw-admin은 버킷 자체를 만들 수 없어서(유저/정책 관리만), bash+openssl로 AWS SigV2 서명을 직접 계산해 S3 API를 호출했다:

```bash
BUCKET="my-bucket"
ACCESS_KEY="..."
SECRET_KEY="..."
RGW_ENDPOINT="10.5.5.6:7480"

DATE=$(date -R)
STRING_TO_SIGN="PUT\n\n\n${DATE}\n/${BUCKET}/"
SIG=$(printf "%b" "$STRING_TO_SIGN" | openssl dgst -sha1 -hmac "$SECRET_KEY" -binary | base64)

curl -X PUT \
  -H "Date: ${DATE}" \
  -H "Authorization: AWS ${ACCESS_KEY}:${SIG}" \
  "http://${RGW_ENDPOINT}/${BUCKET}/"
```

실전에서 반복적으로 오브젝트를 업로드/조회하는 애플리케이션이라면 이 수동 서명 대신 boto3 같은 SDK를 쓰는 게 낫다 — [어플리케이션 샘플](ceph-app-sample.md) 참고.

## CephCluster 관리 (k8s CRD 레벨)

```bash
kubectl -n rook-ceph get cephcluster
kubectl -n rook-ceph get cephblockpool
kubectl -n rook-ceph get cephobjectstore
kubectl -n rook-ceph rollout restart deployment/rook-ceph-operator   # reconcile-stall 복구용
```
