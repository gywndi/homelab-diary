# StarRocks 운영 명령 모음

[`08-1-starrocks-analytics.md`](08-1-starrocks-analytics.md)로 구축한 뒤 실제 쓰면서 반복적으로 쓰는 SQL/명령들. 구축 절차가 아니라 "테이블 만들 때, 데이터 넣을 때, 상태 확인할 때" 참고하는 용도. 전부 `mysql -h fe.starrocks.svc.cluster.local -P 9030 -u root` 클라이언트로 실행한다(비밀번호 없음, 기본 상태).

## 테이블 생성

```sql
-- Duplicate Key(원본 로그성 데이터, 중복 허용)
CREATE TABLE events (
  id BIGINT,
  device_id INT,
  event_type VARCHAR(30),
  event_time DATETIME
)
DUPLICATE KEY(id)
DISTRIBUTED BY HASH(id) BUCKETS 4;

-- Primary Key(실시간 갱신 필요 — UPDATE/DELETE 지원)
CREATE TABLE crud_test (id BIGINT, category INT, value DOUBLE, ts DATETIME)
PRIMARY KEY(id) DISTRIBUTED BY HASH(id) BUCKETS 8
PROPERTIES("replication_num"="2");
```

시간 단위 RANGE 파티션을 한 번에 여러 개 만들 수도 있다:

```sql
CREATE TABLE hourly_test (
  id BIGINT,
  event_time DATETIME,
  val INT
) DUPLICATE KEY(id, event_time)
PARTITION BY RANGE(event_time) (
  START ("2026-08-28 00:00:00") END ("2026-08-29 00:00:00") EVERY (INTERVAL 1 HOUR)
)
DISTRIBUTED BY HASH(id) BUCKETS 6
PROPERTIES("replication_num"="2");
```

`START/END/EVERY` 구문으로 24개(1시간 단위) 파티션이 한 번에 생성된다. 파티션 이름은 `p2026082800`, `p2026082801`... 형태로 자동 부여된다.

## 데이터 넣기

작은/중간 규모 테스트 데이터는 `generate_series`로 서버 사이드에서 즉석 생성한다. 편리하지만 CPU 비용이 붙는다는 게 함정이다 — [`08-2` 고카디널리티 재검증](08-2-starrocks-analytics-bmt.md) 참고.

```sql
INSERT INTO events
SELECT id, id % 100, 'boot', DATE_ADD('2026-01-01 00:00:00', INTERVAL id SECOND)
FROM TABLE(generate_series(1, 1000000)) AS t(id);
```

CPU 비용 없이 순수 쓰기 성능만 보고 싶으면 사전 생성한 파일을 STREAM LOAD(HTTP PUT 벌크 로드)로 넣는다. FE의 8030(HTTP) 포트로 보내면 실제 담당 BE/CN으로 자동 리다이렉트된다.

```bash
curl --location-trusted -u root: \
  -H "label:my_load_$(date +%s)" \
  -H "column_separator:," \
  -H "columns: id,customer_id,product_id,quantity,ts,payload" \
  -T /path/to/data.csv \
  "http://fe.starrocks.svc.cluster.local:8030/api/<db>/<table>/_stream_load"
```

응답 JSON의 `LoadTimeMs`/`WriteDataTimeMs`/`LoadBytes`로 처리량을 계산한다.

## 조회

3-way JOIN(MPP) 스타 스키마 집계 예시:

```sql
SELECT c.segment, p.category_name, COUNT(*), SUM(f.quantity * p.unit_price), AVG(f.quantity)
FROM fact f
JOIN customer c ON f.customer_id = c.customer_id
JOIN product p ON f.product_id = p.product_id
WHERE f.ts BETWEEN '2026-03-01' AND '2026-04-01'
GROUP BY c.segment, p.category_name
ORDER BY 4 DESC LIMIT 20;
```

CRUD 시퀀스 예시(Primary Key 테이블):

```sql
-- point SELECT
SELECT * FROM crud_test WHERE id = 150000;

-- 집계 SELECT
SELECT category, COUNT(*), AVG(value) FROM crud_test GROUP BY category ORDER BY category LIMIT 5;

-- UPDATE (Primary Key 테이블은 같은 키로 재 INSERT하면 upsert)
INSERT INTO crud_test SELECT id, category, value*2, ts FROM crud_test WHERE id BETWEEN 1 AND 30000;

-- DELETE
DELETE FROM crud_test WHERE id BETWEEN 270001 AND 300000;
```

클라이언트/파드 기동 오버헤드를 배제하고 순수 서버 처리 시간만 재려면 `NOW(6)`로 앞뒤를 감싼다:

```sql
SELECT NOW(6) AS t_start;
-- 측정하려는 쿼리
SELECT NOW(6) AS t_end;
```

## 클러스터 상태 확인

```sql
SHOW FRONTENDS\G          -- FE 목록, Role(LEADER/FOLLOWER/OBSERVER), Alive
SHOW BACKENDS\G           -- BE 목록
SHOW COMPUTE NODES\G      -- CN 목록
SHOW PARTITIONS FROM t;   -- 파티션별 범위/버킷/행수
SHOW TABLET FROM t PARTITION(p2026082800);  -- 태블릿-노드 매핑(분산 확인용)
```

`SHOW TABLET`의 출력 스키마로 cloud-native와 classic OLAP 테이블을 구분할 수 있다 — classic은 태블릿마다 `ReplicaId`가 있고 `replication_num`만큼 여러 행이 나오지만, cloud-native는 태블릿당 한 행에 `BackendId` 배열만 나온다.

테이블이 진짜 로컬인지 cloud-native인지 확인:

```sql
SHOW CREATE TABLE my_table\G
```

`"storage_volume" = "builtin_storage_volume"` / `"datacache.enable" = "true"`가 있으면 cloud-native(RGW 기반). `"replicated_storage" = "true"`만 있고 `storage_volume`이 없으면 classic OLAP(로컬 저장). `replication_num` 프로퍼티를 지정했다고 해서 로컬이라고 착각하지 말 것 — 클러스터의 `run_mode`가 shared_data면 테이블 속성과 무관하게 전부 cloud-native다.

## 노드 추가/제거

```sql
ALTER SYSTEM ADD BACKEND "sn-be1-0.sn-be1-hl.starrocks-sn.svc.cluster.local:9050";
ALTER SYSTEM ADD COMPUTE NODE "cn-0.cn-hl.starrocks.svc.cluster.local:9050";
ALTER SYSTEM ADD OBSERVER "fe-obs1-0.fe-obs1-hl.starrocks.svc.cluster.local:9010";
```

FE/BE/CN 전부 headless Service의 고정 hostname으로 등록한다 — IP로 등록하면 파드가 재시작될 때마다 깨진다. Follower/Observer 차이는 [concepts/starrocks.md](../concepts/starrocks.md#fe-확장-follower-vs-observer) 참고.
