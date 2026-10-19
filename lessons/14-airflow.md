# Airflow (워크플로 스케줄러) + DAG 저장소

[← 이전: GitLab](13-gitlab.md)

k8s 위에 Apache Airflow 3를 가장 가볍게 세우고, 작업 정의(DAG)를 GitLab 저장소에서 받아 쓰도록 연결한다. Airflow는 "A 작업이 끝나면 B 작업을 실행한다" 같은 순서와 일정을 코드로 정의해 돌려 주는 워크플로 스케줄러다. 작업 흐름 하나를 DAG(Directed Acyclic Graph, 순환 없는 방향 그래프)라고 부르며 파이썬 파일 하나로 쓴다. 이 문서는 Airflow 본체, 메타데이터 DB(기존 MySQL), 외부 노출(도메인·인증서), DAG를 담는 GitLab 저장소와 브랜치 규칙까지 전부 다룬다.

## 목적

홈랩에서 쓸 배치·데이터 작업의 실행기를 만든다. 조건은 세 가지다.

- 가능한 한 가볍게 구성한다. 파드 하나, 추가 DB 없음.
- DAG의 원천은 GitLab에만 둔다. 서버에서 파일을 직접 고치지 않는다.
- `main`에 검증을 통과한 코드만 들어가고, Airflow는 `main`만 가져간다.

## 구성 한눈에

| 요소 | 값 | 역할 |
|---|---|---|
| Airflow | `apache/airflow:3.3.2-python3.12`, 파드 1개 (`airflow` 네임스페이스) | `airflow standalone` 한 프로세스가 아래 네 개를 모두 실행 |
| api-server | 위 파드 안 (8080) | 웹 UI와 REST API |
| scheduler | 위 파드 안 | DAG의 일정을 보고 실행할 작업을 정함 |
| dag-processor | 위 파드 안 | DAG 파일을 읽어 파싱하고 DB에 등록 |
| triggerer | 위 파드 안 | 대기형 작업(비동기)을 처리 |
| 실행기 | LocalExecutor | 작업을 파드 안 프로세스로 실행 (별도 워커 파드 없음) |
| 메타데이터 DB | 기존 MySQL (`mysql.mysql.svc.cluster.local:3306`, DB `airflow`) | DAG 목록, 실행 이력, 커넥션 저장 |
| 로그 | PVC `airflow-logs` 5Gi (`ceph-csi-rbd`) | 작업 로그 보관, 재시작해도 유지 |
| 웹 접속 | `https://airflow.example.com` → ingress VIP `10.5.5.50` | Let's Encrypt 인증서, ingress-nginx가 HTTPS 종료 |
| 로그인 | `SimpleAuthManager`, 계정 `admin` 하나 | 비밀번호는 Secret `airflow-secrets`의 `admin-password` |
| DAG 소스 | GitLab 프로젝트 `airflow-dags`의 `main` 브랜치 | `GitDagBundle`이 60초마다 가져옴 |
| Git 접속 정보 | Secret `airflow-git` (deploy token) | 읽기 전용 토큰 |

## 설계 결정

- **Helm 차트 대신 Deployment 1개.** 공식 Helm 차트는 api-server·scheduler·dag-processor·triggerer·워커·Redis·PostgreSQL을 따로 띄워 홈랩에는 무겁다. `airflow standalone`은 이 컴포넌트를 한 프로세스 그룹으로 실행한다. 요청 자원은 CPU 0.3코어, 메모리 1Gi, 상한은 메모리 2Gi다.
- **LocalExecutor.** 작업을 파드 안에서 프로세스로 돌린다. 워커 파드나 메시지 큐가 필요 없다. 대신 작업이 파드의 자원을 나눠 쓴다. 병렬 작업 수는 8로 제한했다.
- **메타데이터 DB는 기존 MySQL을 쓴다.** Airflow 3는 MySQL 8을 지원한다. 새 DB 서버를 띄우지 않아도 된다. 데이터베이스는 `utf8mb4` / `utf8mb4_unicode_ci`로 만든다. Airflow는 이 문자 집합을 요구한다. 접속 계정은 `airflow` DB에만 전체 권한을 준다.
- **Deployment(replicas=1) + `Recreate` + Ceph RBD PVC.** GitLab·MySQL과 같은 패턴이다. 노드가 죽으면 다른 노드에서 다시 뜬다. 노드 고정(`nodeSelector`)은 하지 않는다.
- **비밀 값은 Secret에만 둔다.** DB 접속 문자열, Fernet 키(Airflow가 커넥션·변수를 암호화하는 키), JWT 서명 키, API 비밀 키, 관리자 비밀번호를 실행할 때마다 새로 생성해 `airflow-secrets`에 넣는다. 이미 Secret이 있으면 다시 만들지 않는다. Fernet 키를 잃으면 저장된 커넥션·변수를 복호화할 수 없어서, 이 Secret은 다시 만들지 않는 것이 중요하다.
- **Git 접속 정보는 Secret을 따로 둔다 (`airflow-git`).** deploy token은 만료와 교체가 잦지만 Fernet 키 같은 앱 내부 비밀은 거의 바뀌지 않는다. 합쳐 두면 토큰을 교체하다가 Fernet 키를 건드릴 위험이 있다.
- **인증은 SimpleAuthManager다.** Airflow 3의 기본 인증 방식이다. 계정과 비밀번호가 설정 파일 하나에 고정되며 UI에서 사용자 추가나 비밀번호 변경은 할 수 없다. 혼자 쓰는 환경이라 충분하다고 판단했다. 비밀번호는 Secret에서 읽어 시작할 때 init 컨테이너가 `passwords.json`으로 만든다. 그래서 비밀번호를 바꾸려면 Secret을 고치고 파드를 재시작한다.
- **여러 사용자나 DAG 단위 권한이 필요해지면 FAB 인증으로 바꾼다.** 공식 이미지에 `apache-airflow-providers-fab`가 이미 들어 있다. 이 경우 사용자 정보가 MySQL에 저장되고 UI에서 사용자·역할을 관리할 수 있다. `airflow users create`로 초기 관리자를 따로 만들어야 한다.
- **DAG는 GitLab에서 당겨 온다 (pull).** CI가 클러스터에 DAG를 밀어 넣으려면 CI에 클러스터 쓰기 권한이 필요하다. 대신 Airflow가 `main`을 주기적으로 가져간다. Airflow 3의 `GitDagBundle`은 사이드카 컨테이너 없이 이것을 한다. 공식 이미지에 `git` 바이너리와 `apache-airflow-providers-git`이 들어 있어서 커스텀 이미지가 필요 없다.
- **Git 읽기용 deploy token을 쓴다.** 사람 계정의 비밀번호나 개인 토큰 대신, 프로젝트 하나에만 묶이고 `read_repository` 범위만 가진 deploy token을 쓴다. 유출돼도 피해가 이 저장소 읽기로 제한된다.
- **`GitDagBundle`은 실행 시점의 커밋 버전을 기억한다.** 실행 중에 `main`이 바뀌어도 그 실행은 같은 버전의 코드로 끝까지 돈다.
- **DAG 파일은 Airflow 파드에 저장하지 않는다.** 초기에는 ConfigMap에 DAG를 넣었다. 지금은 번들 방식으로 바꿔서 ConfigMap은 쓰지 않는다.
- **`main`에 검증 안 된 코드가 들어가면 Airflow가 그대로 가져간다.** Airflow는 CI 결과를 보지 않는다. 그래서 GitLab에서 `main`을 직접 푸시할 수 없게 막고 파이프라인이 성공해야 병합되게 했다.
- **브랜치는 `develop` → `main` 두 개다.** 작업은 `develop`에 푸시한다. 푸시하면 CI가 자동으로 돈다. 운영은 `main`이고 `develop`에서 `main`으로 MR(Merge Request, 병합 요청)을 열어 파이프라인이 성공해야만 병합한다. `develop`은 상시 브랜치라 보호 브랜치로 두어 삭제를 막는다.
- **기본 브랜치는 `develop`이다.** 저장소를 열면 `develop`이 보인다. 대신 CI 규칙이 기본 브랜치 이름에 의존하지 않도록 `main`을 직접 적는다. MR을 만들 때 기본 대상이 `develop`이 되므로 `main`으로 바꿔야 한다.
- **레지스트리와 커스텀 이미지는 아직 쓰지 않는다.** GitLab의 Container Registry는 메모리 절약을 위해 꺼져 있다. provider를 많이 추가해야 할 때 켜고 이미지를 직접 만든다.

## 대상

| 항목 | 값 |
|---|---|
| 네임스페이스 | `airflow` |
| 이미지 | `apache/airflow:3.3.2-python3.12` |
| 메타데이터 DB | MySQL `airflow` DB (`mysql.mysql.svc.cluster.local:3306`) |
| 공인 도메인 | `airflow.example.com` (공인 DNS A 레코드는 집 공인 IP) |
| 내부 DNS 등록 | `airflow.example.com` → `10.5.5.50` |
| DAG 저장소 | GitLab 프로젝트 `airflow-dags` (private, 기본 브랜치 `develop`) |
| 배포 노드 | chan08, chan09, llm001 중 어디든 (고정 안 함) |

## 스크립트 목록 (이름 순)

### 메타데이터 DB와 Secret 생성
- 설명: Airflow 전용 네임스페이스와 MySQL DB·계정을 만들고, 접속 문자열과 각종 키를 Secret `airflow-secrets`로 저장한다. MySQL root는 파드 안에서 비밀번호 없이 소켓으로 접속한다(`MYSQL_ALLOW_EMPTY_PASSWORD`). 비밀 값은 실행할 때마다 새로 생성한다. 이미 Secret이 있으면 아무것도 하지 않는다.
- 스크립트: [`01-create-db.sh`](../scripts/14-airflow/01-create-db.sh)

```bash
# Airflow 네임스페이스를 만든다
kubectl create namespace airflow --dry-run=client -o yaml | kubectl apply -f -

# MySQL에 DB와 계정을 만든다 (utf8mb4, 해당 DB에만 전체 권한)
kubectl -n mysql exec deploy/mysql -- mysql -uroot -e "
CREATE DATABASE IF NOT EXISTS airflow CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'airflow'@'%' IDENTIFIED BY '<DB 비밀번호>';
ALTER USER 'airflow'@'%' IDENTIFIED BY '<DB 비밀번호>';
GRANT ALL PRIVILEGES ON airflow.* TO 'airflow'@'%';"

# 접속 문자열과 키들을 Secret으로 저장한다
kubectl -n airflow create secret generic airflow-secrets \
  --from-literal=sql-alchemy-conn='mysql+mysqldb://airflow:<DB 비밀번호>@mysql.mysql.svc.cluster.local:3306/airflow' \
  --from-literal=fernet-key='<Fernet 키>' \
  --from-literal=jwt-secret='<JWT 서명 키>' \
  --from-literal=api-secret-key='<API 비밀 키>' \
  --from-literal=admin-password='<관리자 비밀번호>'
```

`<DB 비밀번호>`, `<Fernet 키>`, `<JWT 서명 키>`, `<API 비밀 키>`, `<관리자 비밀번호>`는 `openssl rand`로 실행할 때마다 새로 만들어서 고정할 수 없다. 관리자 비밀번호 확인은 `kubectl -n airflow get secret airflow-secrets -o jsonpath='{.data.admin-password}' | base64 -d`로 한다.

### Airflow 배포
- 설명: Airflow를 Deployment 하나로 배포한다. `airflow standalone`을 LocalExecutor로 실행하고, 비밀 값은 모두 Secret에서 환경변수로 주입한다. DAG는 `GitDagBundle` 설정(`AIRFLOW__DAG_PROCESSOR__DAG_BUNDLE_CONFIG_LIST`)으로 GitLab `main`을 60초마다 가져온다. 시작 전에 init 컨테이너가 관리자 비밀번호 파일을 만든다. 도메인을 인자로 주면 ingress와 Let's Encrypt 인증서도 만든다. Secret `airflow-git`이 없으면 DAG 읽기가 실패하므로, 처음에는 이 스크립트를 직접 실행하지 않고 deploy token 등록 스크립트를 거친다.
- 스크립트: [`02-deploy-airflow.sh`](../scripts/14-airflow/02-deploy-airflow.sh)

```bash
# 로그 PVC, Service, Deployment를 한 번에 적용한다
kubectl apply -f - <<'EOF'
...
EOF

# 도메인을 줬다면 ingress를 만든다 (인증서는 letsencrypt-prod, HTTP-01)
kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: airflow
  namespace: airflow
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: nginx
  tls:
    - hosts: [airflow.example.com]
      secretName: airflow-tls
  rules:
    - host: airflow.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service: {name: airflow, port: {number: 8080}}
EOF

# 파드가 준비될 때까지 기다린다
kubectl -n airflow rollout status deploy/airflow --timeout=600s
```

Deployment의 핵심 설정은 다음과 같다.

- 실행 명령: `airflow standalone`
- 실행기: `AIRFLOW__CORE__EXECUTOR=LocalExecutor`, 병렬 작업 8개
- 예제 DAG 끔: `AIRFLOW__CORE__LOAD_EXAMPLES=False`
- 시간대: `Asia/Seoul`
- 자원: 요청 CPU 300m / 메모리 1Gi, 상한 메모리 2Gi
- 준비 확인: `/api/v2/monitor/health`, 시작 60초 뒤부터 15초마다
- 볼륨: 로그 PVC를 `/opt/airflow/logs`에, 비밀번호 파일용 `emptyDir`를 `/opt/airflow/auth`에 마운트

### 관리자 비밀번호 변경
- 설명: 새 비밀번호를 화면에 표시하지 않고 두 번 입력받아 Secret의 `admin-password`를 바꾸고 Airflow를 재시작한다. 12자 미만이면 거부한다. 재시작 중에는 UI가 잠시 끊기고 실행 중인 작업도 함께 끊긴다.
- 스크립트: [`03-set-admin-password.sh`](../scripts/14-airflow/03-set-admin-password.sh)

```bash
# Secret의 admin-password 값을 새 비밀번호(base64)로 바꾼다
kubectl -n airflow patch secret airflow-secrets --type merge -p '{"data":{"admin-password":"<새 비밀번호 base64>"}}'

# 파드를 재시작한다 (init 컨테이너가 새 값으로 비밀번호 파일을 다시 만든다)
kubectl -n airflow rollout restart deploy/airflow

# 재시작이 끝날 때까지 기다린다
kubectl -n airflow rollout status deploy/airflow --timeout=600s
```

`<새 비밀번호 base64>`는 입력한 비밀번호에서 만들어지므로 고정할 수 없다.

### Git 번들 연결 (deploy token 등록)
- 설명: Airflow가 GitLab의 DAG 저장소를 읽을 수 있게 한다. 먼저 GitLab 프로젝트의 Settings → Repository → Deploy tokens에서 `read_repository` 범위만 가진 토큰을 만든다. 스크립트는 토큰의 사용자명과 값을 화면에 표시하지 않고 입력받아 Secret `airflow-git`에 저장하고, 이어서 `02-deploy-airflow.sh`를 실행해 번들 설정이 들어간 Deployment를 적용한다.
- 스크립트: [`04-enable-git-bundle.sh`](../scripts/14-airflow/04-enable-git-bundle.sh)

```bash
# Git 커넥션(JSON)을 Secret으로 저장한다
kubectl -n airflow create secret generic airflow-git --from-literal=conn='{"conn_type":"git","host":"https://git.example.com/<소유자>/airflow-dags.git","login":"<토큰 사용자명>","password":"<토큰 값>"}' --dry-run=client -o yaml | kubectl apply -f -

# 번들 설정이 들어간 Deployment를 적용한다
./02-deploy-airflow.sh
```

`<토큰 사용자명>`과 `<토큰 값>`은 GitLab이 토큰을 만들 때 발급하는 값이라 고정할 수 없다. Secret의 `conn` 값은 Deployment에서 환경변수 `AIRFLOW_CONN_GITLAB_DAGS`로 주입된다. 번들 설정은 다음과 같다.

```json
[{"name":"airflow-dags","classpath":"airflow.providers.git.bundles.git.GitDagBundle","kwargs":{"git_conn_id":"gitlab_dags","tracking_ref":"main","subdir":"dags","refresh_interval":60}}]
```

- `git_conn_id`: 위의 `AIRFLOW_CONN_GITLAB_DAGS`가 가리키는 커넥션 이름(`gitlab_dags`)이다.
- `tracking_ref`: 추적할 브랜치다. `main`만 가져간다.
- `subdir`: 저장소에서 DAG를 읽을 폴더다. `dags/` 안만 읽는다.
- `refresh_interval`: 60초마다 가져온다.

### DAG 저장소 브랜치 규칙
- 설명: DAG 저장소에 브랜치 규칙을 적용한다. `main`은 아무도 직접 푸시할 수 없고 병합은 Maintainer만 하며 파이프라인이 성공해야 병합된다. `develop`은 Developer 이상이 푸시할 수 있고 강제 푸시는 금지한다. 보호 브랜치라서 삭제할 수 없다. 기본 브랜치를 `develop`으로 바꾸고, 병합 후 소스 브랜치를 자동으로 지우는 설정은 끈다(켜 두면 병합할 때 `develop`을 지우려 한다). 프로젝트와 두 브랜치는 미리 푸시해 둬야 한다.
- 스크립트: [`05-protect-dags-repo.sh`](../scripts/14-airflow/05-protect-dags-repo.sh)

```bash
# GitLab 안에서 프로젝트 설정과 보호 브랜치를 바꾼다
kubectl -n gitlab exec deploy/gitlab -- gitlab-rails runner '...'
```

러너 안에서 하는 일은 다음과 같다.

- 프로젝트: "파이프라인 성공 시에만 병합"을 켜고, "병합 후 소스 브랜치 삭제"를 끈다.
- `main`: 푸시 권한을 없음(0)으로 바꾼다. 병합 권한은 Maintainer(40)다.
- `develop`: 푸시 Developer(30), 병합 Maintainer(40), 강제 푸시 금지로 보호 브랜치를 만든다.
- 기본 브랜치를 `develop`으로 바꾼다.

## 외부 노출 (도메인·내부 DNS·인증서)

Airflow의 도메인 작업은 스크립트가 아니라 기존 스크립트를 재사용한다.

```bash
# 내부 DNS(CoreDNS)에 airflow.example.com → 10.5.5.50 을 등록한다 (GitLab 구성의 스크립트 재사용)
./scripts/13-gitlab/03-add-ssh-dns.sh airflow.example.com

# ingress와 인증서는 위의 배포 스크립트에 도메인을 인자로 줘서 만든다
./scripts/14-airflow/02-deploy-airflow.sh airflow.example.com

# 인증서가 발급됐는지 확인한다
kubectl -n airflow get certificate
```

- **내부 DNS 등록이 먼저 필요한 이유.** cert-manager는 인증서를 발급하기 전에, 클러스터 안에서 챌린지 URL에 요청을 보내 스스로 확인한다. 이때 클러스터 DNS가 새 이름을 모르면 확인이 실패해 인증서가 `READY False`로 멈춘다.
- **공인 DNS의 A 레코드는 집 공인 IP를 가리켜야 한다.** Let's Encrypt가 밖에서 80번 포트로 챌린지를 확인한다.
- **외부 노출 범위.** 공유기가 80/443을 ingress로 포워딩하므로 도메인은 곧 외부 공개다. 로그인이 관리자 계정 하나이므로 비밀번호를 12자 이상으로 유지한다.

## DAG 저장소 (GitLab 프로젝트 `airflow-dags`)

DAG 저장소는 `~/gitlab/airflow-dags`에 두고, GitLab 안에서는 `airflow-dags` 프로젝트(private)다. 프로젝트는 GitLab에 저장소를 처음 푸시할 때 자동으로 만들어졌다(push-to-create).

### 디렉터리 구조

```
airflow-dags/
├── dags/                       # Airflow가 읽는 DAG만 둔다 (도메인별 폴더)
│   └── examples/
│       ├── hello.py            # 예제: 매일 한 번 echo
│       └── sync_check.py       # 동기화 확인용 예제
├── include/                    # DAG가 import하는 공용 함수, SQL
├── tests/
│   └── test_dag_integrity.py   # DAG 무결성 테스트
├── compose.yaml                # 로컬 실행 (운영과 같은 이미지)
├── pyproject.toml              # ruff, pytest 설정
├── .gitlab-ci.yml              # CI 검증
└── README.md
```

- `dags/`와 `include/`를 나눈 이유: `GitDagBundle`의 `subdir`를 `dags`로 지정해 Airflow가 DAG만 읽게 하고, 공용 코드는 DAG 파싱 대상에서 뺀다.

### CI 파이프라인

```yaml
image: apache/airflow:3.3.2-python3.12

workflow:
  rules:
    - if: $CI_COMMIT_BRANCH && $CI_OPEN_MERGE_REQUESTS && $CI_PIPELINE_SOURCE == "push"
      when: never
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH == "develop" || $CI_COMMIT_BRANCH == "main"

variables:
  PIP_DISABLE_PIP_VERSION_CHECK: "1"
  AIRFLOW__CORE__LOAD_EXAMPLES: "false"

validate:
  rules:
    - changes: [dags/**/*, include/**/*, tests/**/*, pyproject.toml, .gitlab-ci.yml]
  script:
    - pip install --quiet --user ruff pytest
    - export PATH="$HOME/.local/bin:$PATH"
    - ruff check .
    - python -m pytest -q tests
```

- **검증용이지 배포용이 아니다.** 이 파이프라인은 DAG가 깨지지 않았는지만 확인한다. 배포는 Airflow가 `main`을 가져가는 방식이다.
- **`validate`가 하는 일.** `ruff`로 문법·import 정렬을 검사하고, `pytest`로 DAG 무결성을 확인한다.
- **무결성 테스트 내용.** 모든 DAG가 import 오류 없이 로드되는지, DAG에 태그가 있는지, 모든 태스크에 owner가 있는지를 본다.
- **실행되는 경우.** `develop` 푸시와 `main` 병합, 그리고 MR에서 돈다. 단, `develop`에 열린 MR이 있으면 푸시 파이프라인은 건너뛰고 MR 파이프라인만 돈다. 같은 검증이 두 번 도는 것을 막기 위해서다.
- **관련 없는 변경에서는 건너뛴다.** `dags/`, `include/`, `tests/`, `pyproject.toml`, CI 파일이 바뀔 때만 돈다.
- **규칙에 기본 브랜치 변수를 쓰지 않는다.** 기본 브랜치가 `develop`이라 `$CI_DEFAULT_BRANCH`를 쓰면 `main` 병합 후 파이프라인이 사라진다. 그래서 `"main"`을 직접 적는다.
- **예제 DAG 로드를 끈다.** CI 이미지는 기본값이 예제 DAG를 불러와서 `LOAD_EXAMPLES=false`로 끈다.

### 로컬 개발

```bash
# 운영과 같은 이미지로 Airflow를 띄운다 (dags/ 마운트, DB는 SQLite)
docker compose up
```

`http://localhost:8080`으로 접속하고 비밀번호는 시작 로그에 한 번 출력된다. 이미지가 운영과 같아서 "내 컴퓨터에서는 되는데 운영에서는 안 된다"를 줄인다. DAG 하나만 실행해 보려면 컨테이너 안에서 `airflow dags test <DAG 이름>`을 쓴다.

### 브랜치 전략

| 브랜치 | 푸시 | 병합 | 삭제 | 용도 |
|---|---|---|---|---|
| `develop` | Developer 이상 | Maintainer | 불가 (보호) | 작업 브랜치, 푸시하면 CI 자동 실행 |
| `main` | 아무도 불가 | Maintainer, 파이프라인 성공 필수 | 불가 (보호) | 운영, Airflow가 가져가는 브랜치 |

작업 흐름은 다음과 같다.

1. `develop`에 커밋하고 푸시한다. CI(`ruff`, `pytest`)가 자동으로 돈다.
2. `develop` → `main` MR을 연다. 대상 브랜치는 기본값이 `develop`이므로 `main`으로 바꾼다. 푸시 옵션 `git push -o merge_request.create -o merge_request.target=main`을 쓰면 처음부터 `main`으로 만들 수 있다.
3. 파이프라인이 성공하면 병합한다. 실패하면 병합 버튼이 막혀서 잘못된 DAG가 `main`에 들어가지 못한다.
4. 병합 후 Airflow가 60초 안팎에 새 DAG를 반영한다.

## 알려진 이슈

### 설정 맵을 DAG 폴더에 그대로 마운트하면 DAG 탐색이 무한 루프로 오인한다
초기에 DAG를 ConfigMap으로 넣었을 때, ConfigMap 마운트의 심볼릭 링크(`..data`) 구조를 dag-processor가 재귀 루프로 판단해 실패했다. emptyDir에 복사해서 해결했고, 이후 `GitDagBundle` 방식으로 바꾸면서 ConfigMap 자체를 쓰지 않는다.

### 새 도메인은 클러스터 DNS에 등록하지 않으면 인증서가 발급되지 않는다
공인 DNS에는 있는 이름이라도 클러스터 안 CoreDNS가 모르면 cert-manager 자체 확인이 `no such host`로 실패한다. 내부 DNS에 이름을 등록하고 챌린지를 지워 재시도하게 했다.

### 공유기 DNS가 새 이름을 이 Mac에서 못 풀 수 있다
인증서 발급과 외부 접속이 정상이어도, 공유기 DNS가 새 이름에 일시적으로 NXDOMAIN을 주면 로컬에서 접속이 안 된다. 외부망에서는 정상이다. 공인 IP로 `--resolve` 지정해 접속해 보면 서비스 자체는 확인된다.

### DDNS 갱신 목록은 클러스터 밖에서 관리하며 이 구성에 포함되지 않는다
집 공인 IP가 바뀌면 DDNS 호스트 목록에 없는 이름은 옛 IP를 가리킨다. 이 목록은 클러스터에 없고(예전 NAS 스케줄러 스크립트에 있다), `airflow.example.com`은 아직 등록하지 않았다.

### Airflow 3의 `DagBag`에는 `include_examples` 인자가 없다
테스트에서 `DagBag(dag_folder=..., include_examples=False)`를 쓰면 `TypeError`가 난다. 인자를 빼고 예제 로드는 환경변수 `AIRFLOW__CORE__LOAD_EXAMPLES=false`로 끈다.

### `main`에 직접 푸시하면 CI를 우회한다
보호 브랜치라도 푸시 권한이 Maintainer면 소유자가 CI 없이 `main`에 올릴 수 있다. 그러면 Airflow가 그대로 가져간다. 푸시 권한을 없음으로 바꿔 막았다.

### 토큰 Secret 없이 배포 스크립트를 먼저 실행하면 dag-processor가 실패한다
Deployment가 `airflow-git` Secret을 참조하므로 deploy token 등록 스크립트를 먼저 실행해야 한다.

### SimpleAuthManager에는 UI에서 비밀번호를 바꾸는 기능이 없다
스크립트로 Secret을 바꾸고 파드를 재시작해야 한다. 재시작 중에는 UI가 끊기고 실행 중인 작업도 끊긴다.

## 검증 명령

```bash
# 파드, PVC, ingress 확인
kubectl -n airflow get pods,pvc,ingress

# 인증서 발급 상태 확인
kubectl -n airflow get certificate

# 구성 요소 상태 확인 (네 개 모두 healthy여야 한다)
kubectl -n airflow port-forward svc/airflow 18080:8080
curl -s localhost:18080/api/v2/monitor/health

# 메타데이터 DB에 테이블이 만들어졌는지 확인
kubectl -n mysql exec deploy/mysql -- mysql -uroot -e "select count(*) from information_schema.tables where table_schema='airflow'"

# dag-processor가 번들을 갱신하는지 로그로 확인
kubectl -n airflow logs deploy/airflow -c airflow --tail=200 | grep "Refreshing bundle"

# HTTPS 응답과 인증서 발급자 확인
curl -s -o /dev/null -w "%{http_code} verify=%{ssl_verify_result}\n" https://airflow.example.com/

# DAG 저장소의 보호 브랜치와 기본 브랜치 확인
kubectl -n gitlab exec deploy/gitlab -- gitlab-rails runner 'p=Project.find_by_full_path("<소유자>/airflow-dags"); puts p.default_branch; p.protected_branches.each { |b| puts "#{b.name} push=#{b.push_access_levels.map(&:access_level)} merge=#{b.merge_access_levels.map(&:access_level)}" }'
```

`<소유자>`는 GitLab 프로젝트 소유자 계정 이름이다.

## 검증 이력

- 2026-10-19: Airflow 3.3.2를 `airflow standalone` + LocalExecutor로 배포했다. 메타데이터 DB(MySQL)에 71개 테이블이 만들어지고 health가 database·scheduler·triggerer·dag-processor 모두 healthy인 것을 확인했다. ConfigMap으로 넣은 DAG는 심볼릭 링크 루프로 dag-processor가 실패해서, 복사 방식으로 고친 뒤 `hello` DAG가 목록에 나타나는 것을 확인했다.
- 2026-10-19: 도메인과 ingress를 추가했다. 처음에는 클러스터 DNS가 새 이름을 몰라 인증서가 발급되지 않았다. 내부 DNS에 이름을 등록한 뒤 Let's Encrypt 인증서가 발급되어 공인 IP로 접속하면 HTTP 200과 인증서 검증 통과를 확인했다. 이 Mac에서는 공유기 DNS가 이름을 못 풀었다.
- 2026-10-19: DAG 저장소 프로젝트를 만들고 CI를 돌렸다. 처음 두 번은 `DagBag` 인자 오류와 예제 DAG 로드로 실패했고, 수정 후 `2 passed`로 통과했다.
- 2026-10-19: deploy token으로 `GitDagBundle`을 연결했다. `hello` DAG의 출처가 GitLab 번들로 바뀌었고, 테스트 DAG를 푸시하자 약 30초 만에 Airflow 목록에 나타났다.
- 2026-10-19: `main` 직접 푸시를 막고 파이프라인 성공 시에만 병합하게 설정했다. `main`에 직접 푸시를 시도하자 `pre-receive hook declined`로 거부되는 것을 확인했다.
- 2026-10-19: `develop` → `main` 전략을 적용했다. `develop` 푸시에서 파이프라인이 자동으로 돌고, `develop` → `main` MR 파이프라인이 성공해 병합됐다. 이어서 기본 브랜치를 `develop`으로 바꾸고 CI 규칙을 `main` 고정으로 고쳐 병합했다. 브랜치 규칙 스크립트를 다시 실행해 같은 상태가 유지되는 것을 확인했다.
- 2026-10-19: 관리자 비밀번호 변경 스크립트와 FAB 인증 전환은 문서화만 했고 실제로 실행해 검증하지 않았다.

---

[← 이전: GitLab](13-gitlab.md)
