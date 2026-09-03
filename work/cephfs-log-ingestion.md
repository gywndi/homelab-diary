# CephFS 로그 적재 성능 조사 (진행 중)

k8s 여러 파드가 공통 경로에 실시간으로 로그를 append하는 용도로 CephFS(`logfs`)를 추가했다. 이 문서는 그 성능/내구성 트레이드오프를 라운드별로 검증하는 초안이다 — 결론이 굳어지면 `lessons/07-1-ceph-storage.md`/`07-2-ceph-storage-bmt.md`로 정리해 옮긴다.

배경: [concepts/02-ceph.md의 CephFS 항목](../concepts/02-ceph.md#cephfs), 빌드 절차는 [lessons/07-1-ceph-storage.md의 CephFS 볼륨 생성](../lessons/07-1-ceph-storage.md#cephfs-볼륨-생성-로그-적재용-rwx).

## 1라운드 (2026-09-03): append 처리량, MDS failover, fsync 내구성, IO 스케줄러

### append 처리량 — RADOS append와 비교

같은 워크로드(45바이트 로그 줄 500개 연속 append)를 RADOS append(테스트 풀, EC/replicated 각각)와 CephFS(커널 클라이언트 마운트)에서 비교했다.

| 방식 | 회당 지연 |
|---|---|
| RADOS append, replicated | 49.1ms |
| RADOS append, EC k=2,m=1 | 61.6ms |
| CephFS append(fsync 없음, 기본 buffered) | 8.9ms |

CephFS가 5.5~6.9배 빠르게 나왔다. 다만 이 비교는 애초에 공정하지 않다 — `rados append`는 매 호출이 동기(synchronous) 쓰기라 반환 시점에 이미 replication/EC 정책대로 커밋이 끝나 있다. 반면 CephFS 쪽은 `tee -a`로 그냥 썼을 뿐이라 커널 page cache(dirty page)에 들어간 순간 반환된다 — 아직 OSD에 실제로 flush되기 전일 수 있다. 즉 8.9ms는 "안전하게 커밋 완료"가 아니라 "로컬 캐시에 넣는 데까지 걸린 시간"이라 내구성 수준이 다른 두 숫자를 그대로 비교한 것이었다.

### MDS failover 중 쓰기

active MDS(`mds.logfs.chan09`)를 `ceph orch daemon restart`로 강제 재기동시키면서 그 창구로 append를 시도했다 — 에러도 데이터 유실도 없었다. standby(llm001)가 즉시 active로 전환됐고, 재시작된 chan09는 정상적으로 standby로 복귀했다(`ceph fs status`로 확인).

### fsync로 내구성 수준 맞춰서 재측정

위 비교의 불공정함을 바로잡기 위해, `rados append`와 같은 수준(매 쓰기마다 커밋 확인)으로 맞추려면 CephFS 쪽도 매 줄마다 `fsync()`를 호출해야 한다. Python으로 `os.write()` + `os.fsync()`를 직접 호출하는 벤치마크를 만들어 재측정했다(`/tmp/fsync_test.py`, 아래 재현 방법 참고).

| durability 수준 | 처리량 | 회당 지연 | 최악의 경우 유실량 |
|---|---|---|---|
| fsync 매줄 | 87~119 ops/sec (아래 참고) | 8.4~11.6ms | ~0(거의 무손실) |
| fsync 10줄마다 | 811 ops/sec | 1.23ms | 최대 9줄 |
| fsync 100줄마다 | 8,052 ops/sec | 0.12ms | 최대 99줄 |
| fsync 안 함(순수 buffered) | 163,415 ops/sec | 0.01ms | OS 자동 플러시 주기만큼(수 초치) — 실제 백엔드 처리량이 아니라 "메모리 복사 속도"에 불과 |

fsync 매줄 수준(87~119 ops/sec, 8.4~11.6ms)으로 다시 비교하면, 그래도 `rados append`(replicated 49.1ms/20.4 ops/sec)보다 CephFS가 4~5배 빠르다 — 같은 내구성 기준으로 맞춰도 CephFS가 유리하다는 결론 자체는 유지된다. 클라이언트가 capability로 파일을 캐시해두고 쓰기를 처리하는 구조가, 매번 풀에 직접 append하는 RADOS 방식보다 유리한 것으로 보인다(정확한 원인은 미검증 — 아래 "다음에 검증할 것" 참고).

**buffered I/O와 OS 설정의 관계**: fsync 없이 그냥 `write()`만 하면 커널 page cache에 들어가고 즉시 반환된다 — 실제 플러시는 커널이 나중에 알아서 한다. `vm.dirty_expire_centisecs`/`vm.dirty_ratio`/`vm.dirty_background_ratio` 같은 sysctl로 "명시적 fsync 없이도 최대 몇 초 안엔 어차피 반영된다"는 상한을 걸 수 있다 — "매줄 fsync(느림, 거의 무손실)"과 "아예 안 함(빠름, 유실 위험)" 사이의 중간 지점으로 쓸 수 있다. 이번 라운드에서는 이 옵션 자체는 실측하지 않았다.

**O_DIRECT는 이 워크로드엔 안 맞는다**: page cache를 아예 안 거치는 대안이지만, 보통 정렬된(aligned, 512B/4KB 단위) I/O를 요구한다 — 가변 길이 텍스트 로그 줄엔 안 맞아서 검토 대상에서 제외했다.

### IO 스케줄러 — 차이 없음

OSD 백엔드 디스크(chan08/chan09 `sda`)가 `mq-deadline`으로 설정돼 있어서(SSD엔 보통 `none`이 권장됨) `none`으로 바꿔 재측정했다. 처음엔 87→119 ops/sec으로 개선되는 것처럼 보였으나, 웜업 효과(네트워크 연결 재사용, MDS 캡 유지)와 뒤섞여 있었다 — `mq-deadline`으로 되돌려서 같은 웜업 상태로 대조군을 다시 재보니 116 ops/sec으로 `none`과 사실상 동일했다. **이 워크로드에서 IO 스케줄러 선택은 유의미한 차이를 만들지 않는다.** 병목은 스케줄러가 아니라 fsync마다 발생하는 네트워크 왕복(클라이언트→OSD→ack) 자체로 보인다. 스케줄러는 실측 후 원래 값(`mq-deadline`)으로 되돌려뒀다.

## 다음에 검증할 것

- fsync 매줄 처리량(87~119 ops/sec)의 편차가 큰 이유 — 웜업 외에 다른 변동 요인이 있는지
- CephFS가 같은 내구성 수준에서도 RADOS append보다 빠른 정확한 원인(캡 기반 배칭인지, 프로토콜 자체의 차이인지) — 현재는 추정만 했음
- `vm.dirty_expire_centisecs` 등 OS 자동 플러시 튜닝으로 "매줄 fsync 없이 유실량 상한만 거는" 중간 지점의 실제 처리량
- 여러 클라이언트(노드별 daemon 여럿)가 동시에 각자 다른 파일에 append할 때의 집계 처리량(지금까지는 단일 클라이언트 순차 테스트만 했음)
- MDS 캐시 압박(1GB 한도 근처까지 파일/디렉터리를 늘렸을 때) 실측 — 지금까지는 파일 1~2개 수준이라 캐시 압박 자체가 유발되지 않았음

## 재현 방법

```bash
# CephFS 마운트 (클라이언트 인증은 lessons/07-1-ceph-storage.md 참고)
sudo mount -t ceph logtest@<fsid>.logfs=/ /mnt/logfs-test \
  -o secretfile=/etc/ceph/logtest.secret,mon_addr=10.5.5.8:6789/10.5.5.9:6789/10.5.5.10:6789

# fsync 벤치마크 (fsync_every=1이면 매줄, 숫자를 키우면 N줄마다)
python3 fsync_test.py /mnt/logfs-test/test.log <반복횟수> <fsync_every>
```
```python
# fsync_test.py
import os, sys, time
path, n, fsync_every = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
line = b'2026-09-03T10:00:00 GET /api/health 200 12ms\n'
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
start = time.time()
for i in range(1, n + 1):
    os.write(fd, line)
    if fsync_every == 1 or i % fsync_every == 0:
        os.fsync(fd)
os.fsync(fd)
elapsed = time.time() - start
os.close(fd)
print(f'{n} appends, fsync every {fsync_every}: {elapsed:.3f}s total, {elapsed/n*1000:.2f}ms/append, {n/elapsed:.0f} ops/sec')
```
```bash
# IO 스케줄러 확인/변경 (OSD 백엔드 디스크, 재부팅 시 원복됨)
cat /sys/block/sda/queue/scheduler
echo none | sudo tee /sys/block/sda/queue/scheduler

# MDS failover 유발
ceph orch daemon restart mds.logfs.<현재 active 이름>
```
