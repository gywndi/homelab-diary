# StarRocks shared-data 배포

RGW(S3 호환 오브젝트 스토리지) 위에 StarRocks FE 1 + CN 1을 shared-data(컴퓨팅/스토리지 분리) 모드로 배포하는 스크립트.

## 사전 조건

- `scripts/07-ceph-storage/`의 RGW(오브젝트 스토어)가 배포되어 있고 서비스 `rgw-starrocks-store-lb.rook-ceph.svc:7480`로 접근 가능해야 함
- RGW에 StarRocks 전용 유저 + 버킷이 만들어져 있어야 함 (아래 00 스크립트)

## 실행 순서

1. `00-create-rgw-user-and-bucket.sh` — RGW에 `starrocks` 유저 생성 + `starrocks-storage` 버킷 생성, access/secret key를 k8s Secret으로 저장
2. `01-deploy-fe.sh` — FE(Frontend) 배포. headless Service로 안정적인 DNS 아이덴티티(`fe-0.fe-hl...`)를 부여하는 것이 핵심 — 그렇지 않으면 FE가 자기 자신을 클러스터 DNS로 못 찾는 이름으로 등록해버린다.
3. `02-deploy-cn.sh` — CN(Compute Node) 배포 + FE에 등록. CN도 FE와 동일하게 headless Service + 고정 hostname 필요.
4. `03-verify.sh` — DB/테이블 생성 + INSERT + SELECT로 RGW까지 실제로 데이터가 쓰이는지 end-to-end 확인

## 알려진 특성

- **첫 테이블 생성이 느리다(콜드 스타트).** 실측 60~300초 걸림 — 기본 `tablet_create_timeout_second`(10초)로는 무조건 타임아웃난다. `fe.conf`에 60초로 미리 늘려뒀지만, 첫 시도가 그래도 실패하면 `ADMIN SET FRONTEND CONFIG("tablet_create_timeout_second"="300")`로 늘려서 한 번 통과시키면 이후는 3초 내외로 빨라진다.
- FE/CN 모두 **StatefulSet이 아니라 Deployment + headless Service + 고정 hostname/subdomain**을 쓴다 — 단일 replica라 StatefulSet의 순번 관리가 실익 없고, 핵심은 "클러스터 DNS로 항상 같은 이름으로 자기 자신을 찾을 수 있는 것"뿐이라 이 조합으로 충분하다.
- CN을 IP로 등록하면 파드가 재시작될 때마다 IP가 바뀌어 재등록이 필요하다 — 반드시 headless Service FQDN으로 등록할 것(`ALTER SYSTEM ADD COMPUTE NODE "cn-0.cn-hl.starrocks.svc.cluster.local:9050"`).
