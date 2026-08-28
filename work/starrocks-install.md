# StarRocks 설치

> 이 문서는 초안이다. 검증까지 끝나면 `lessons/`로 옮겨 다듬는다. 아키텍처 배경 지식은 [StarRocks 소개](starrocks-intro.md) 참고. 전제 조건: [Ceph 설치](ceph-install.md)에서 RGW(오브젝트 스토리지)가 이미 배포되어 있어야 한다.

두 개의 서로 다른 클러스터를 배포했다 — ① `starrocks` 네임스페이스: shared-data(FE + CN, RGW 기반), ② `starrocks-sn` 네임스페이스: 진짜 shared-nothing(FE + BE, 로컬 XFS 기반). `run_mode`가 클러스터 생성 시 고정되고 나중에 못 바꾸기 때문에(아래 이슈 참고), 두 모드를 비교하려면 완전히 별도의 FE가 필요했다.

## 설계 결정

- **StatefulSet이 아니라 Deployment + headless Service.** 공식 StarRocks Kubernetes Operator는 StatefulSet 기반이지만, 이 규모(단일/소수 인스턴스, BMT 테스트)에서는 순번 관리 같은 StatefulSet의 이점이 필요 없다. 실제로 필요했던 건 딱 하나 — "클러스터 DNS로 항상 같은 이름으로 자기 자신을 찾을 수 있는 것"뿐이라, `clusterIP: None`인 headless Service + 파드의 `hostname`/`subdomain` 필드 조합만으로 충분했다.
- **RGW 자격증명은 git에 올리지 않는다.** fe.conf는 파일 형태라 k8s Secret을 네이티브로 참조할 수 없어서, 배포 스크립트가 Secret에서 값을 읽어 `sed`로 템플릿에 주입한 뒤 ConfigMap으로 적용하는 방식을 택했다.
- **버킷 생성은 radosgw-admin이 아니라 수동 서명한 S3 PUT으로 한다.** radosgw-admin은 유저/정책 관리만 하고 버킷 자체는 S3 API로만 만들 수 있다. awscli 등 별도 도구를 설치하는 대신, bash+openssl로 AWS SigV2 서명을 직접 계산해서 처리했다.
- **shared-nothing 클러스터(`starrocks-sn`)는 완전히 별도 네임스페이스.** `run_mode`가 클러스터 생성 시 고정되고 나중에 못 바꾸기 때문에, 기존 클러스터를 고치는 게 아니라 새 FE를 `run_mode` 지정 없이(기본값) 배포했다. BE 3개는 기존 XFS 파티션의 하위 디렉토리(`/mnt/starrocks-be/sn-data`)를 써서, 기존 shared-data 클러스터의 datacache와 물리적으로 분리했다.

## shared-data 배포 (`starrocks` 네임스페이스)

1. RGW에 유저/버킷 생성, k8s Secret 저장
2. FE 배포 — self-identity FQDN(`fe-0.fe-hl.starrocks.svc.cluster.local`) 정상 확인 필수
3. CN 배포 + FE 등록, `SHOW BACKENDS`/`SHOW COMPUTE NODES`로 Alive 확인
4. end-to-end 검증 — 테이블 생성 + INSERT + SELECT, RGW 버킷 오브젝트 수 증가로 실제 저장 확인
5. 3노드 대칭 구성으로 확장 — chan09/llm001에도 각각 CN 추가(`02-deploy-cn.sh`를 이름/노드만 바꿔 반복 실행)
6. FE 코디네이터 병목 실험을 위해 Follower FE 2개(fe2/fe3) 추가 — `ALTER SYSTEM ADD FOLLOWER`로 리더에 먼저 등록 후 `--helper` 플래그로 기동

## shared-nothing 배포 (`starrocks-sn` 네임스페이스)

1. 3노드 모두 기존 XFS 파티션에 `sn-data` 하위 디렉토리 생성(기존 shared-data BE의 datacache와 분리)
2. FE 배포 — `run_mode` 지정 없이(기본값), RGW/S3 설정 전혀 없음. self-identity `fe-0.fe-hl.starrocks-sn.svc.cluster.local` 확인
3. 3노드(chan08/chan09/llm001)에 각각 BE 배포 + 등록 — `SHOW BACKENDS`로 BackendId 전부 Alive 확인
4. 검증: `SHOW CREATE TABLE`에 `storage_volume` 없이 `"replicated_storage"="true"`만 있으면 성공(cloud-native와 구분되는 표시). 데이터 로드 후 노드의 로컬 `data/` 디렉토리에 실제로 바이트가 쌓이는지, `du -sh`로 직접 확인할 것 — 이 확인을 안 해서 이번 세션 중반에 크게 헤맸다.

## 실행 중 발견한 이슈

- **이미지 기본 CMD가 k8s에서는 그냥 tini usage만 찍고 끝난다.** `docker run`으로는 되는 것 같은 기본 CMD가 k8s Deployment에서는 아무 프로그램도 못 찾은 채 tini가 usage 메시지만 출력하고 종료됐다. `command: ["/opt/starrocks/fe/bin/start_fe.sh"]`(BE는 `start_be.sh`, CN은 `start_cn.sh`)를 명시적으로 지정해야 했다.
- **FE/CN/BE가 자기 자신을 클러스터 DNS로 못 찾는 이름으로 등록해버렸다.** `--host_type FQDN`으로 기동했는데 headless Service 없이 일반 Deployment로 띄우니, 파드가 자기 identity를 무작위 호스트명(예: `fe-8648f9875-7wbh2`)으로 잡아버렸다 — 클러스터 DNS에 등록된 이름이 아니라서 서로 통신이 끊겼다(`Could not resolve host for client socket`). headless Service(`clusterIP: None`) + 고정 `hostname`/`subdomain`으로 안정적인 FQDN을 부여하는 것으로 해결.
- **"영구히 멈춘 것처럼 보였지만 사실 그냥 느렸다."** 첫 테이블 생성 시도가 매번 타임아웃났고, CN 로그의 `task_count_in_queue`가 계속 늘어나기만 해서 "CN이 뭔가에 완전히 막혔다"고 오판했다. RGW 자체 로그를 직접 열어보고서야 실제로는 S3 요청이 낮은 지연시간(1ms 미만)으로 계속 성공하고 있다는 걸 확인했다 — 콜드 스타트 상태에서 첫 테이블 생성에 필요한 절대적인 단계 수가 많아 오래 걸렸을 뿐. `tablet_create_timeout_second`를 300초로 임시로 늘려서 한 번 통과시키니, 이후 테이블 생성은 3초 내외로 정상화됐다(이후 60초로 축소).
- **`aws_s3_enable_path_style_access` 같은 fe.conf 키는 실제로 존재하지 않는다.** 검색으로 찾은 정보를 믿고 넣었는데, StarRocks 소스(`Config.java`)를 직접 확인하니 이 키 자체가 없었다. 커스텀 엔드포인트를 지정하면 path-style이 자동 적용되는 것으로 보였다(RGW 로그로 실제 요청 형식 확인).
- **BlueStore/디스크 재분할 이슈는 [Ceph 설치](ceph-install.md)의 "디스크 재분할" 섹션 참고** — StarRocks BE의 로컬 XFS 스토리지를 만드는 전제 작업이라 겹친다.
- **FE Follower 등록이 첫 시도에서 조용히 실패했다.** `ALTER SYSTEM ADD FOLLOWER` 실행 직후 바로 새 FE 파드를 띄우면 "current node is not added to the group. please add it first"를 반복하며 무한 재시도하는 경우가 있었다(원인 불명 — 타이밍 이슈로 추정). `SHOW PROC '/frontends'`로 실제 등록 여부를 확인하고, 안 됐으면 `ALTER SYSTEM ADD FOLLOWER`를 재실행하니 곧바로 성공했다.
- **FE Follower conf에 RGW 자격증명을 빠뜨릴 뻔했다.** 팔로워도 cloud-native 테이블 쿼리를 조정하려면 storage volume을 해석해야 해서, 리더와 동일한 `aws_s3_*` 설정이 필요하다 — 처음 작성한 follower conf 템플릿에서 이걸 빠뜨렸다가 배포 직전에 발견해 수정.

## 스크립트 목록

- [`00-create-rgw-user-and-bucket.sh`](../scripts/08-starrocks/00-create-rgw-user-and-bucket.sh) — RGW 유저/버킷 생성, k8s Secret 저장
- [`01-deploy-fe.sh`](../scripts/08-starrocks/01-deploy-fe.sh) + [`fe.conf.template`](../scripts/08-starrocks/fe.conf.template) — shared-data FE 배포(headless Service + 고정 hostname)
- [`02-deploy-cn.sh`](../scripts/08-starrocks/02-deploy-cn.sh) + [`cn.conf`](../scripts/08-starrocks/cn.conf) — CN 배포 + FE 등록. 3노드 전체에 두려면 이름/노드를 바꿔 반복 적용
- [`03-verify.sh`](../scripts/08-starrocks/03-verify.sh) — end-to-end 검증 (DB/테이블/INSERT/SELECT)
- [`04-deploy-be-hybrid.sh`](../scripts/08-starrocks/04-deploy-be-hybrid.sh) — (⚠️ 결과적으로 cloud-native였음, [BMT](starrocks-bmt.md) 참고) 기존 shared-data FE에 BE 추가 등록하던 초기 시도
- [`09-deploy-sn-fe.sh`](../scripts/08-starrocks/09-deploy-sn-fe.sh) — 진짜 shared-nothing FE를 `starrocks-sn` 네임스페이스에 배포
- [`10-deploy-sn-be.sh`](../scripts/08-starrocks/10-deploy-sn-be.sh) — `starrocks-sn` FE에 로컬 스토리지 BE 등록(노드별 반복, `<노드> <접미사>`)
- [`16-add-fe-followers.sh`](../scripts/08-starrocks/16-add-fe-followers.sh) — FE Follower 2개 추가(코디네이터 병목 실험용)
- [`app-sample.py`](../scripts/08-starrocks/app-sample.py) — 실제 동작하는 클라이언트 샘플, 상세는 [어플리케이션 샘플](starrocks-app-sample.md)
