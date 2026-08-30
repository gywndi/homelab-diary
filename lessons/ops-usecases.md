# k8s 활용 사례 모음

[← 이전: 리눅스 기본 상식](ops-linux-basics.md)

이 클러스터 build 문서(01~09) 바깥에서, "이런 것도 k8s로 옮길 수 있다"는 구체적 활용 사례를 모아둔다. 각 사례는 실제로 겪은(또는 검토한) 상황을 가상의 값으로 바꿔서 남긴다.

## 사례: 외부 API를 주기 호출하는 배치를 CronJob으로

기존에 다른 곳(예: NAS 자체 작업 스케줄러)에서 돌리던 "주기적으로 외부 API 하나 호출하는" 류의 배치를 k8s CronJob으로 옮기는 최소 템플릿. 실제 사례를 가상의 도메인으로 바꿔서 남긴다 — 동적 DNS(DDNS) 갱신 API를 5분마다 호출하던 NAS의 shell 스크립트를 그대로 옮긴 것.

### 원본 (NAS 작업 스케줄러, sh)

```sh
#!/bin/sh
PROPERTIES=(
  "box.example.com"
  "example.com"
  "www.example.com"
  "chat.example.com"
  "blog.example.com"
)
DOMAIN_LIST=""
for DOMAIN in ${PROPERTIES[@]}
do
  if [ "$DOMAIN_LIST" != "" ]; then
    DOMAIN_LIST="${DOMAIN_LIST}&"
  fi
  DOMAIN_LIST="${DOMAIN_LIST}host[${DOMAIN}]"
done
/usr/bin/wget -O - --http-user=<사용자명> --http-passwd=<비밀번호> "http://dyna.example-ddns.com/update.php?$DOMAIN_LIST"
```

### 옮기는 원칙

- **자격증명은 절대 매니페스트에 평문으로 안 넣는다.** `kubectl create secret`으로 먼저 등록하고, CronJob은 `secretKeyRef`로만 참조한다.
- **이미지는 가장 가벼운 걸로.** curl 하나만 필요하면 `curlimages/curl` 같은 수십MB짜리로 충분하다 — 이 저장소의 다른 헬스체크/벤치마크 파드들도 같은 원칙([`ops-k8s.md`](ops-k8s.md) 참고).
- **`concurrencyPolicy: Forbid`.** 이전 실행이 아직 안 끝났는데 다음 스케줄이 겹치는 걸 막는다. 이런 단순 API 호출류 배치에서는 거의 항상 이게 맞는 선택이다.
- **`backoffLimit`은 낮게.** 기본값(6)은 이런 가벼운 작업엔 과하다 — 실패해도 어차피 5분 뒤 다시 도니 재시도를 오래 끌 이유가 없다.

### 1단계: 네임스페이스

```bash
kubectl create namespace ddns
```

### 2단계: 자격증명을 Secret으로

```bash
kubectl -n ddns create secret generic ddns-credentials \
  --from-literal=username=<사용자명> \
  --from-literal=password=<비밀번호>
```

확인 (값 자체를 보고 싶을 때만):
```bash
kubectl -n ddns get secret ddns-credentials -o jsonpath='{.data.username}' | base64 -d; echo
```

### 3단계: CronJob 매니페스트

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ddns-update
  namespace: ddns
spec:
  schedule: "*/5 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: ddns-update
              image: curlimages/curl:8.10.1
              env:
                - name: DDNS_USER
                  valueFrom:
                    secretKeyRef:
                      name: ddns-credentials
                      key: username
                - name: DDNS_PASS
                  valueFrom:
                    secretKeyRef:
                      name: ddns-credentials
                      key: password
              command:
                - sh
                - -c
                - |
                  curl -sS -u "${DDNS_USER}:${DDNS_PASS}" \
                    "http://dyna.example-ddns.com/update.php?host[box.example.com]&host[example.com]&host[www.example.com]&host[chat.example.com]&host[blog.example.com]"
```

원본의 `wget --http-user/--http-passwd`는 curl의 `-u user:pass`(basic auth)와 동일하다. 도메인 목록은 원본 스크립트의 반복문 결과물(`host[도메인1]&host[도메인2]&...`)을 그대로 정적으로 박아넣었다 — 도메인이 자주 안 바뀌면 굳이 셸 반복문을 컨테이너 안에서 다시 돌릴 필요가 없다.

### 4단계: 적용

```bash
kubectl apply -f ddns-cronjob.yaml
```

### 5단계: 검증

```bash
# 등록 확인
kubectl -n ddns get cronjob

# 5분을 안 기다리고 지금 바로 1회 수동 실행
kubectl -n ddns create job ddns-manual-test --from=cronjob/ddns-update

# 결과 로그 (성공하면 API 응답이 그대로 찍힘)
kubectl -n ddns logs job/ddns-manual-test

# 테스트 Job 정리
kubectl -n ddns delete job ddns-manual-test
```

### 운영 중 확인

```bash
# 최근 실행된 Job/Pod 목록 (시간순)
kubectl -n ddns get pods --sort-by=.metadata.creationTimestamp

# 가장 최근 실행 로그
kubectl -n ddns logs -l job-name=<위에서 확인한 파드 이름>

# 스케줄 자체를 잠깐 멈추고 싶을 때 (삭제 안 하고 보류)
kubectl -n ddns patch cronjob ddns-update -p '{"spec":{"suspend":true}}'
kubectl -n ddns patch cronjob ddns-update -p '{"spec":{"suspend":false}}'
```

### 이관 시 체크리스트

원래 스케줄러(NAS 등)에서 같은 작업을 계속 돌리고 있다면 k8s CronJob과 중복 호출된다 — 기능 문제는 거의 없지만(멱등한 API 호출이라면), 확인이 끝나면 원래 쪽 스케줄은 꺼두는 게 깔끔하다.

---

[← 이전: 리눅스 기본 상식](ops-linux-basics.md)
