# StarRocks 튜닝 포인트

> 이 문서는 초안이다. 검증까지 끝나면 `lessons/`로 옮겨 다듬는다. [토스 기술 블로그: StarRocks 운영기 1편](https://toss.tech/article/operating-starrocks-1)(Resource Group 기반 워크로드 격리)을 기준선으로 삼아, 우리 클러스터(3노드 홈랩, k8s Deployment 기반 FE/BE/CN)에 뭘 적용할 수 있고 뭐가 아직 전제조건조차 안 갖춰져 있는지 정리한다. 배경은 [소개](starrocks-intro.md), 우리가 실측으로 확인한 병목은 [BMT](starrocks-bmt.md) 참고.

## 원문 핵심 요약

토스는 서비스 조회 쿼리와 배치 적재/분석 쿼리가 같은 클러스터에서 서로 밀어내는 문제를 **Resource Group**으로 해결했다.

- **`cpu_weight`**: 소프트 격리. CPU 경합이 생겼을 때만 설정 비율대로 나눠 쓰고, 유휴 시엔 다른 그룹이 자유롭게 쓴다.
- **`exclusive_cpu_cores`**: 하드 격리. `pthread_setaffinity_np`로 스레드를 물리 코어에 직접 바인딩하고 전용 ThreadPool까지 분리한다 — 레이턴시 SLA가 엄격한 서비스 쿼리에 씀.
- **Classifier**(쿼리를 어느 Resource Group으로 보낼지 결정하는 규칙)는 `user`/`db` 기반이 `query_type` 기반보다 안정적이다(가중치가 더 높게 설계돼 있음).
- **`big_query_*` 제한**으로 폭주 쿼리를 자동 종료(CPU 초, 스캔 행수, 메모리 기준) — 단, 이 제한은 클러스터 전체가 아니라 **각 BE/CN 노드 기준으로 개별 판단**된다.
- Docker 환경에서 `exclusive_cpu_cores`가 실제로 코어를 격리하려면 `--cpuset-cpus`(어떤 코어를 쓸 수 있는지) + `--cpus`(사용량 상한) + `be.conf`의 `enable_resource_group_bind_cpus=true`가 전부 갖춰져야 한다 — 하나라도 빠지면 상위 설정 자체가 무효화된다.
- 실측 트레이드오프: 92코어 BE에서 `exclusive_cpu_cores=50` 적용 후 CPU 부하는 98%→60%로 줄었지만, INSERT 쿼리 실행 시간은 280초→380~457초로 늘었다 — **격리는 공짜가 아니다.**

## 우리 클러스터에 바로 적용 가능한 것

### 1. Classifier(워크로드 분리) 원칙은 지금 당장 참고할 만하다

우리는 지금까지 모든 벤치마크를 `root` 유저 하나로만 실행했다 — 실제로 서비스를 붙인다면, 원문 권고대로 **`db` 또는 `user` 기준으로 Resource Group을 나누는 게** `query_type` 기준보다 안정적일 것이다. 예를 들어 StarRocks를 실서비스에 연결한다면:

```sql
CREATE RESOURCE GROUP service_wg
TO (user='service_app')
WITH ('cpu_weight' = '50', 'mem_limit' = '40%', 'concurrency_limit' = '30');

CREATE RESOURCE GROUP batch_wg
TO (user='batch_loader')
WITH ('cpu_weight' = '10', 'mem_limit' = '60%');
```

지금 우리 벤치마크 스크립트들도 실제로는 "동시 조회(concurrency 테스트)"와 "대용량 적재(STREAM LOAD/INSERT)"라는 서로 다른 워크로드를 섞어서 같은 CN에 밀어넣고 있었다 — Resource Group 없이 순서대로 실행해서 우연히 안 겹쳤을 뿐, 실서비스라면 이 둘이 충돌할 수 있다.

### 2. `big_query` 제한 — 지금 당장 없어서 아쉬웠던 안전장치

이번 세션에서 실수로 무거운 쿼리를 잘못 걸었을 때(예: 킬 타이밍 이슈, `internal/specs/implementation-plan.md`의 "클라는 왜 죽었지?" 사례) 서버 사이드에서 자동으로 끊어주는 장치가 없었다 — 클라이언트를 강제로 죽여도 서버 쪽 DDL/쿼리는 계속 실행됐다. `big_query_cpu_second_limit`/`big_query_scan_rows_limit` 같은 설정이 있었다면 이런 상황에서 자동 방어가 됐을 것이다. 벤치마크/개발 환경에도 낮은 값으로 걸어두는 걸 검토할 만하다.

### 3. AuditLoader 기반 모니터링 — 우리에게 가장 크게 빠져 있는 부분

원문은 `starrocks_audit_db__.starrocks_audit_tbl__`(AuditLoader 플러그인이 자동 적재하는 감사 로그 테이블)로 `pendingTimeMs`(큐 대기), `state='ERR'`(강제 종료), `cpuCostNs`를 지속적으로 관측한다. **우리는 이번 세션 내내 벤치마크할 때마다 `mpstat`을 수동으로 SSH 실행해서 확인했다** — 일회성 진단으로는 충분했지만, 상시 운영이라면 AuditLoader를 설치해서 쿼리 이력을 영구적으로 남기는 게 맞는 방향이다. 특히 이번에 발견한 "FE가 CN과 같은 노드에 있으면 병목"이나 "CN=3에서 꼬리 지연이 늘어난다" 같은 패턴은, AuditLoader 로그의 `pendingTimeMs` 분포를 봤다면 mpstat 없이도 훨씬 빨리 잡았을 것이다.

## 우리 환경에서 아직 전제조건조차 없는 것

### exclusive_cpu_cores는 지금 당장 못 쓴다 — k8s 쪽 전제조건이 없다

원문의 Docker 체크리스트(`--cpuset-cpus` + `--cpus` + `enable_resource_group_bind_cpus=true`)를 k8s로 옮기면 이렇게 된다:

| Docker 개념 | k8s 대응 | 우리 현재 상태 |
|---|---|---|
| `--cpuset-cpus`(사용 가능 코어 지정) | kubelet `--cpu-manager-policy=static` + Pod가 **Guaranteed QoS**(CPU `requests`==`limits`)일 때만 코어 고정 할당 | ❌ FE/BE/CN 파드 전부 `resources.limits.cpu` 자체가 없음([BMT](starrocks-bmt.md) "컨테이너 CPU 제한 확인" 참고) — QoS가 Burstable/BestEffort라 코어 고정이 아예 안 됨 |
| `--cpus`(사용량 상한) | CPU `limits` 값 | ❌ 미설정 |
| `be.conf: enable_resource_group_bind_cpus=true` | 동일(파드 안 설정 파일) | ❌ 미적용 |

즉 지금 상태로 `exclusive_cpu_cores`를 설정해봐야 원문이 경고한 것과 똑같이 **상위 설정이 없어서 하위 설정이 무효화**된다. 실제로 적용하려면 순서대로:
1. FE/BE/CN Deployment에 `resources.requests.cpu == resources.limits.cpu` 설정(Guaranteed QoS 확보)
2. kubelet의 CPU Manager policy를 `static`으로 전환(전 노드 재구성 필요, 재부팅 유발 가능성 있음 — 신중히)
3. `be.conf`/`cn.conf`에 `enable_resource_group_bind_cpus=true` 추가
4. 그 다음에야 Resource Group의 `exclusive_cpu_cores`가 의미를 가짐

이건 우리 세션에서 실측한 "FE가 CN과 같은 노드에 있으면 그 노드가 병목"([BMT](starrocks-bmt.md) "동시성 병목") 문제와는 **다른 종류의 문제**라는 점이 중요하다 — Resource Group은 **같은 BE/CN 프로세스 안에서 여러 쿼리(워크로드)가 서로 밀어내는 것**을 막는 도구이지, FE 프로세스와 CN 프로세스가 같은 노드의 OS 자원을 나눠 쓰는 것(우리가 해결한 문제)은 애초에 Resource Group의 대상이 아니다. 우리 문제는 k8s `nodeSelector`/`podAntiAffinity` 같은 **파드 배치** 레벨에서 풀어야 했고, 실제로 그렇게 풀었다.

### 이종 스펙 노드 제약 — 우리도 해당된다

원문: "`exclusive_cpu_cores`의 상한은 가장 작은 코어 수를 가진 노드 - 1". 우리 클러스터는 chan08/chan09가 6코어, llm001이 12코어로 **이미 이종 스펙**이다 — 나중에 `exclusive_cpu_cores`를 도입한다면 상한을 6코어 노드 기준(즉 5 이하)으로 잡아야 하고, llm001의 여유 코어는 이 설정 하나로는 활용할 수 없다. 이번 세션에서 llm001의 여유 코어를 실제로 활용한 방법은 Resource Group이 아니라 **FE를 그 노드로 옮기는 배치 조정**이었다는 게 재확인된다.

## 다음 스텝 후보 (백로그)

- [ ] FE/BE/CN에 CPU `requests`/`limits`를 실제로 설정해보고(Guaranteed QoS), Resource Group 없이도 이게 우리가 관찰한 "노드 co-location 병목"에 영향을 주는지 재검증
- [ ] AuditLoader 플러그인 설치 + `pendingTimeMs` 기반으로 이전 벤치마크(동시성/CN 확장)를 다시 관측 — mpstat 수동 확인 대비 얼마나 더 빨리/정확히 병목을 잡는지 비교
- [ ] `cpu_weight` 기반 Resource Group을 실제로 만들어서, CN 하나에 "가벼운 조회 워크로드"와 "무거운 배치 워크로드"를 동시에 걸었을 때 격리 효과가 있는지 실측(지금까지는 두 워크로드를 항상 순서대로만 테스트해서 이 상황 자체를 실측한 적이 없음)
- [ ] `big_query_scan_rows_limit`을 낮게 걸어두고 일부러 무거운 쿼리를 날려 자동 종료가 동작하는지 확인
- [ ] 토스 아티클 2편("FE/BE/CN 서버 설정, Ansible 템플릿, 프로덕션 장애 사례")이 나오면 같은 방식으로 우리 환경 대비표 갱신
