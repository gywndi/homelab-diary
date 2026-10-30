# Superset (BI 대시보드) + Snowflake 연결

[← 이전: Airflow](14-airflow.md)

k8s 위에 Apache Superset을 가장 가볍게 세우고, Snowflake를 데이터 소스로 연결한다. Superset은 SQL로 데이터를 조회해 차트와 대시보드로 보여 주는 BI(Business Intelligence, 데이터 분석·시각화) 도구다.

## 목적

Snowflake에 쌓인 데이터를 대시보드로 확인하는 시험 환경을 만든다. 조건은 세 가지다.

- 가능한 한 가볍게 구성한다. 파드 하나, 별도 DB·캐시 서버 없음.
- Snowflake는 Airflow와 같은 서비스 계정(`SVC_AIRFLOW`)과 키 쌍 인증으로 붙는다.
- 외부 도메인으로 HTTPS 접속한다.

## 구성 한눈에

| 요소 | 값 | 역할 |
|---|---|---|
| Superset | `apache/superset:6.1.0-py312`, 파드 1개 (`superset` 네임스페이스) | 웹 UI와 쿼리 실행 |
| 메타데이터 DB | 이미지에 내장된 SQLite | 대시보드·차트·연결 정보 저장 |
| 저장소 | PVC `superset-home` 2Gi (`ceph-csi-rbd`), 마운트 `/app/superset_home` | SQLite 파일, Snowflake 드라이버, 개인키 보관 |
| 자원 | 요청 CPU 0.2코어·메모리 1Gi, 메모리 상한 2Gi | |
| 웹 접속 | `https://superset.example.com` → ingress VIP `10.5.5.50` | Let's Encrypt 인증서 |
| 로그인 | 관리자 `admin` | 비밀번호는 Secret `superset-secrets`의 `admin-password` |
| Snowflake 드라이버 | `snowflake-sqlalchemy<2` + `sqlalchemy<1.5` | PVC의 `pylibs`에 설치 |
| Snowflake 접속 | 서비스 사용자 `SVC_AIRFLOW`, 롤 `AIRFLOW_APP`, 웨어하우스 `DBT_WH` | 키 쌍 인증 |

## 설계 결정

- **Helm 차트 대신 Deployment 1개.** 공식 차트는 Redis, Celery 워커, PostgreSQL을 함께 띄워 시험용으로는 무겁다. 이 구성은 파드 하나가 웹과 쿼리를 모두 처리한다. 대신 비동기 쿼리와 알림 리포트는 쓸 수 없다.
- **메타데이터 DB는 SQLite다.** 별도 DB 서버가 필요 없다. Superset이 앞으로 SQLite 메타데이터 지원을 없앨 예정이라는 경고를 띄우므로 시험용으로만 쓴다. 오래 쓰려면 기존 MySQL로 옮긴다.
- **`Recreate` 전략 + Ceph RBD PVC.** RBD 볼륨은 한 노드에만 붙을 수 있어서, 새 파드가 뜨기 전에 옛 파드를 먼저 내린다.
- **`enableServiceLinks: false`.** 서비스 이름이 `superset`이면 k8s가 `SUPERSET_PORT=tcp://10.x.x.x:8088` 환경변수를 파드에 넣는다. Superset은 이 값을 포트 번호로 읽으려다 `'tcp' is not a valid port number`로 죽는다. 서비스 링크 주입을 끄면 해결된다.
- **비밀 값은 Secret에만 둔다.** `SECRET_KEY`(세션·저장된 연결 비밀번호 암호화 키)와 관리자 비밀번호를 실행할 때 생성해 `superset-secrets`에 넣는다. Secret이 이미 있으면 다시 만들지 않는다. `SECRET_KEY`를 잃으면 저장된 연결 정보를 복호화할 수 없다.
- **시작할 때 DB 마이그레이션과 관리자 생성을 한다.** 컨테이너 명령이 `superset db upgrade` → 관리자 생성(이미 있으면 건너뜀) → `superset init`(기본 역할·권한 초기화) → 서버 기동 순서로 실행한다. 이미지 업그레이드에도 같은 명령이 그대로 동작한다.
- **Snowflake 드라이버는 PVC에 설치한다.** 공식 이미지에는 Snowflake 드라이버가 없고, 이미지의 가상환경(`/app/.venv`)은 쓰기 권한이 없다. 컨테이너 시작 때 `uv pip install --target /app/superset_home/pylibs`로 PVC에 설치하고 `PYTHONPATH`로 읽는다. 이미 설치돼 있으면 빠르게 끝난다.
- **SQLAlchemy는 1.4로 고정한다.** `snowflake-sqlalchemy` 2.x를 그냥 설치하면 SQLAlchemy가 2.x로 올라가 Superset이 깨진다. `snowflake-sqlalchemy<2`와 `sqlalchemy<1.5`를 함께 지정한다.
- **Snowflake 키는 파일 경로로 지정한다.** Superset은 Secure Extra에서 PEM 텍스트(`privatekey_body`) 또는 파일 경로(`privatekey_path`)만 받는다. base64 값은 받지 않는다. PEM 텍스트는 줄바꿈이 조금만 틀어져도 `mismatched tags`로 실패해서, 키를 PVC의 파일로 두고 경로만 적는다.
- **Airflow와 같은 서비스 계정을 쓴다.** 시험 목적이라 사용자와 키를 새로 만들지 않는다. 읽기 권한만 준 롤 `AIRFLOW_APP`으로 접속한다. 운영에서는 Superset 전용 사용자와 롤을 따로 만든다.

## 대상

| 항목 | 값 |
|---|---|
| 실행 위치 | chan08(`10.5.5.8`)에서 `kubectl` 실행 |
| 네임스페이스 | `superset` |
| 도메인 | `superset.example.com` → ingress VIP `10.5.5.50` |

## 스크립트 목록 (이름 순)

### Superset 배포

- 설명: 네임스페이스, Secret, PVC, 서비스, Deployment를 만들고, 도메인을 주면 ingress와 인증서도 만든다. Snowflake 드라이버 설치가 컨테이너 시작 명령에 들어 있다.
- 스크립트: [`01-deploy-superset.sh`](../scripts/15-superset/01-deploy-superset.sh)

```bash
# 내부 DNS(CoreDNS)에 도메인을 등록한다 (GitLab 구성의 스크립트 재사용)
./scripts/13-gitlab/03-add-ssh-dns.sh superset.example.com

# 네임스페이스를 만든다
kubectl create namespace superset

# 키와 비밀번호를 생성해 Secret을 만든다 (Secret이 없을 때만). 값은 실행마다 달라서 고정할 수 없다
kubectl -n superset create secret generic superset-secrets \
  --from-literal=secret-key="<openssl rand -base64 42 결과>" \
  --from-literal=admin-password="<openssl rand -hex 12 결과>"

# PVC, Service, Deployment를 적용한다 (이미지 apache/superset:6.1.0-py312)
kubectl apply -f <01-deploy-superset.sh가 만드는 매니페스트>

# 컨테이너 시작 명령: 드라이버 설치 → 마이그레이션 → 관리자 생성 → 초기화 → 서버 기동
bash -c 'set -e; \
  uv pip install --quiet --python /app/.venv/bin/python --target /app/superset_home/pylibs "snowflake-sqlalchemy<2" "sqlalchemy<1.5"; \
  superset db upgrade; \
  superset fab create-admin --username admin --firstname Admin --lastname User --email admin@example.com --password "$ADMIN_PASSWORD" || echo "admin 이미 있음"; \
  superset init; \
  exec /usr/bin/run-server.sh'

# 도메인을 줬다면 ingress(letsencrypt-prod)와 인증서를 만든다
kubectl -n superset apply -f <ingress 매니페스트: superset.example.com → svc superset:8088>

# 롤아웃과 인증서 발급을 기다린다
kubectl -n superset rollout status deploy/superset --timeout=900s
kubectl -n superset wait --for=condition=Ready certificate/superset-tls --timeout=300s
```

### Snowflake 개인키 배치

- 설명: Airflow 커넥션 `snowflake_app`에 저장된 개인키를 PEM 파일로 만들어 Superset 파드의 PVC에 둔다. 키를 화면이나 로컬 디스크에 남기지 않고 두 파드 사이로 바로 전달한다. 헤더·푸터를 맞추고 64자로 줄바꿈해 PEM 형식 오류를 막는다.
- 스크립트: [`02-install-snowflake-key.sh`](../scripts/15-superset/02-install-snowflake-key.sh)

```bash
# Airflow 파드에서 키를 꺼내 PEM으로 정리하고, 바로 Superset 파드의 PVC 파일로 쓴다 (권한 600)
kubectl -n airflow exec -i <airflow 파드> -c airflow -- python - | \
  kubectl -n superset exec -i <superset 파드> -- bash -c 'umask 077; cat > /app/superset_home/snowflake_key.pem'

# 키가 유효한지, 공개키 지문이 Snowflake에 등록된 값과 같은지 확인한다
kubectl -n superset exec <superset 파드> -- bash -c 'openssl pkey -in /app/superset_home/snowflake_key.pem -pubout -outform DER | openssl dgst -sha256 -binary | base64'
```

## Snowflake에서 실행할 권한 SQL

`SVC_AIRFLOW`가 `AIRFLOW_APP` 롤로 `DBT_DEV`를 읽을 수 있어야 연결이 된다. ACCOUNTADMIN으로 실행한다. 이미 있는 객체는 건너뛰므로 여러 번 실행해도 된다.

```sql
USE ROLE ACCOUNTADMIN;

CREATE ROLE IF NOT EXISTS AIRFLOW_APP;

CREATE WAREHOUSE IF NOT EXISTS DBT_WH WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE;

CREATE DATABASE IF NOT EXISTS DBT_DEV;

GRANT ROLE AIRFLOW_APP TO USER SVC_AIRFLOW;

GRANT USAGE ON WAREHOUSE DBT_WH TO ROLE AIRFLOW_APP;

GRANT USAGE ON DATABASE DBT_DEV TO ROLE AIRFLOW_APP;

GRANT USAGE ON ALL SCHEMAS IN DATABASE DBT_DEV TO ROLE AIRFLOW_APP;

GRANT SELECT ON ALL TABLES IN DATABASE DBT_DEV TO ROLE AIRFLOW_APP;

GRANT SELECT ON ALL VIEWS IN DATABASE DBT_DEV TO ROLE AIRFLOW_APP;

GRANT SELECT ON ALL DYNAMIC TABLES IN DATABASE DBT_DEV TO ROLE AIRFLOW_APP;

GRANT USAGE ON FUTURE SCHEMAS IN DATABASE DBT_DEV TO ROLE AIRFLOW_APP;

GRANT SELECT ON FUTURE TABLES IN DATABASE DBT_DEV TO ROLE AIRFLOW_APP;

GRANT SELECT ON FUTURE VIEWS IN DATABASE DBT_DEV TO ROLE AIRFLOW_APP;

GRANT SELECT ON FUTURE DYNAMIC TABLES IN DATABASE DBT_DEV TO ROLE AIRFLOW_APP;
```

- **`FUTURE` 권한을 함께 준다.** `ALL`은 지금 있는 객체에만 적용된다. dbt가 나중에 만드는 스키마와 테이블에도 읽기 권한이 자동으로 붙게 하려면 `FUTURE`가 필요하다.
- **쓰기 권한은 주지 않는다.** Superset에서 `INSERT`나 `CREATE`는 되지 않는다.

## 연결 만들기 (Superset UI)

Settings → Database Connections → + Database에서 Snowflake를 고르고, SQLAlchemy URI로 직접 입력하는 방식으로 넘어간다.

```text
# SQLAlchemy URI
snowflake://SVC_AIRFLOW@<조직>-<계정>/DBT_DEV?warehouse=DBT_WH&role=AIRFLOW_APP
```

```json
{
  "auth_method": "keypair",
  "auth_params": {
    "privatekey_path": "/app/superset_home/snowflake_key.pem"
  }
}
```

- `<조직>-<계정>`은 환경마다 다른 Snowflake 계정 식별자라 고정할 수 없다.
- URI는 `/<데이터베이스>`를 경로에 쓰고 비밀번호는 넣지 않는다.
- JSON은 Advanced → Security → Secure Extra에 넣는다.
- Test Connection이 성공하면 저장한다.

## 알려진 이슈

### 기동 직후 `'tcp' is not a valid port number`로 죽는다

서비스 이름 `superset` 때문에 k8s가 넣는 `SUPERSET_PORT` 환경변수를 Superset이 포트로 읽는다. `enableServiceLinks: false`로 해결한다.

### 새 도메인의 인증서가 발급되지 않는다

공인 DNS 권한 서버 일부가 새 레코드를 아직 못 받았을 때 Let's Encrypt 검증이 NXDOMAIN으로 실패한다. 모든 권한 서버가 응답한 뒤 `Certificate`를 지우면 ingress-shim이 다시 만든다. 준비 상태는 `kubectl wait --for=condition=Ready certificate/superset-tls`로 확인한다. `conditions[0]`은 `Issuing`이라 Ready 판정에 쓰면 안 된다.

### `snowflake-sqlalchemy` 2.x를 설치하면 Superset이 깨진다

SQLAlchemy가 2.x로 올라가기 때문이다. `<2` 와 `sqlalchemy<1.5`로 고정한다.

### Secure Extra의 PEM이 `mismatched tags`로 실패한다

PEM 헤더·푸터가 서로 다르거나 본문에 공백이 끼면 난다. 실제로 Airflow에 저장된 키 하나에 헤더 `BEGIN PRIVATEKEY`(공백 누락)와 본문 공백이 있었다. 파일 경로 방식으로 쓰고, PEM은 정리 스크립트로 만든다.

### `JWT token is invalid`

서명한 개인키가 Snowflake 사용자에 등록된 공개키와 짝이 아닐 때 난다. 공개키 지문(`DESC USER`의 `RSA_PUBLIC_KEY_FP`)과 파일의 지문을 비교한다.

### `Role '...' specified in the connect string is not granted to this user`

URI의 `role`을 사용자가 가진 롤로 맞춘다. 이 사용자는 `AIRFLOW_APP`만 갖고 있다.

### `The requested database does not exist or not authorized`

접속 롤에 데이터베이스 `USAGE`가 없거나 URI의 데이터베이스 이름이 틀렸다. 위 권한 SQL을 실행한다.

### 공개 도메인에 관리자 계정 하나뿐이다

도메인이 곧 외부 공개이므로 로그인 후 관리자 비밀번호를 바꾼다.

### DDNS 갱신 목록은 클러스터 밖에서 관리한다

집 공인 IP가 바뀌면 이 도메인도 옛 IP를 가리킨다. DDNS 갱신 대상에 이 도메인을 추가하는 일은 이 구성에 포함되지 않는다.

## 검증 명령

```bash
# 파드, PVC, ingress 확인
kubectl -n superset get pods,pvc,ingress

# 인증서 발급 상태 확인
kubectl -n superset get certificate

# 서버 상태 확인
curl -s -o /dev/null -w "%{http_code}\n" https://superset.example.com/health

# Snowflake 드라이버가 PVC에 설치돼 있고 SQLAlchemy가 1.4인지 확인
kubectl -n superset exec deploy/superset -- python -c "import sqlalchemy, snowflake.sqlalchemy as s; print(sqlalchemy.__version__, s.__file__)"

# 개인키 파일의 공개키 지문 확인
kubectl -n superset exec deploy/superset -- bash -c 'openssl pkey -in /app/superset_home/snowflake_key.pem -pubout -outform DER | openssl dgst -sha256 -binary | base64'
```

## 검증 이력

- 2026-10-28: Superset 6.1.0을 파드 1개와 SQLite PVC로 배포했다. 처음에는 `SUPERSET_PORT` 환경변수 충돌로 기동에 실패했고, `enableServiceLinks: false`로 해결한 뒤 `/health`가 200을 반환했다.
- 2026-10-28: 도메인과 ingress를 추가했다. 공인 DNS 권한 서버 한 곳이 새 레코드를 받기 전이라 인증서 발급이 한 번 실패했다. 모든 서버가 응답한 뒤 `Certificate`를 지워 다시 발급받았고, 공인 IP로 `/health`와 `/login/`이 200, 인증서 검증 통과를 확인했다.
- 2026-10-30: Snowflake 드라이버를 PVC에 설치했다. `snowflake-sqlalchemy 1.11.1`이 로드되고 SQLAlchemy가 1.4.54로 유지되는 것을 확인했다.
- 2026-10-30: Snowflake 연결을 시도했다. PEM 헤더 오류(`mismatched tags`)와 키 불일치(`JWT token is invalid`)를 차례로 고쳤고, 롤 오류와 데이터베이스 권한 오류까지 확인했다. 개인키 파일 방식과 권한 SQL을 정리했으며, 권한 SQL 실행과 최종 연결 성공은 이 문서 작성 시점에 확인하지 못했다.

---

[← 이전: Airflow](14-airflow.md)
