# StarRocks 어플리케이션 샘플

> 이 문서는 초안이다. 검증까지 끝나면 `lessons/`로 옮겨 다듬는다. 아래 코드는 실제로 클러스터에 연결해 실행·검증했다.

StarRocks는 MySQL 프로토콜(9030 포트)을 그대로 쓰기 때문에, 기존 MySQL 클라이언트 라이브러리를 그대로 쓸 수 있다. 아래는 Python `pymysql`로 접속해 테이블 생성→적재→조회까지 하는 최소 예시다.

## 사전 준비

```bash
pip install pymysql
```

클러스터 밖(로컬 머신)에서 실행하려면 먼저 포트포워딩:

```bash
kubectl -n starrocks port-forward svc/fe 9030:9030
```

클러스터 안(같은 k8s 클러스터의 다른 네임스페이스)에서 실행한다면 `host`를 `fe.starrocks.svc.cluster.local`로 바꾸면 된다.

## 코드

전체 파일: [`scripts/08-starrocks/app-sample.py`](../scripts/08-starrocks/app-sample.py)

```python
import pymysql

conn = pymysql.connect(host="127.0.0.1", port=9030, user="root", password="", autocommit=True)
cur = conn.cursor()

cur.execute("CREATE DATABASE IF NOT EXISTS sample_app")
cur.execute("USE sample_app")
cur.execute("""
    CREATE TABLE IF NOT EXISTS events (
        id BIGINT,
        device_id INT,
        event_type VARCHAR(30),
        event_time DATETIME
    )
    DUPLICATE KEY(id)
    DISTRIBUTED BY HASH(id) BUCKETS 4
""")

cur.execute("""
    INSERT INTO events (id, device_id, event_type, event_time) VALUES
    (1, 101, 'boot', '2026-08-28 00:00:00'),
    (2, 102, 'boot', '2026-08-28 00:01:00'),
    (3, 101, 'heartbeat', '2026-08-28 00:05:00'),
    (4, 103, 'boot', '2026-08-28 00:06:00'),
    (5, 102, 'heartbeat', '2026-08-28 00:10:00')
""")

cur.execute("""
    SELECT event_type, COUNT(*) AS cnt
    FROM events
    GROUP BY event_type
    ORDER BY cnt DESC
""")
print("event_type breakdown:", cur.fetchall())

cur.execute("SELECT * FROM events WHERE device_id = 101 ORDER BY event_time")
print("device 101 events:", cur.fetchall())

cur.execute("DROP TABLE events")
cur.execute("DROP DATABASE sample_app")
cur.close()
conn.close()
print("OK")
```

## 실행 결과 (실제 검증)

```
$ python3 scripts/08-starrocks/app-sample.py
event_type breakdown: (('boot', 3), ('heartbeat', 2))
device 101 events: ((1, 101, 'boot', datetime.datetime(2026, 8, 28, 0, 0)), (3, 101, 'heartbeat', datetime.datetime(2026, 8, 28, 0, 5)))
OK
```

## 실전에서 고려할 점

- **`autocommit=True`가 사실상 필수다.** StarRocks는 트랜잭션 모델이 전통 RDBMS와 달라서(로드/커밋 단위가 다름), 일반적인 ORM의 암묵적 트랜잭션 관리에 의존하면 예상과 다르게 동작할 수 있다.
- **대량 적재는 INSERT 반복이 아니라 STREAM LOAD를 쓸 것.** 위 예시처럼 몇 건 안 되는 데이터는 INSERT로 충분하지만, 수만 건 이상이면 [사용쿼리 예시](starrocks-query-examples.md)의 STREAM LOAD 패턴(HTTP PUT 벌크 로드)이 훨씬 빠르다 — 실측 비교는 [BMT](starrocks-bmt.md) 참고.
- **읽기 전용 쿼리는 FE Follower로도 분산 가능하다.** 멀티 FE 구성이라면 커넥션 풀을 여러 FE 엔드포인트에 분산시킬 수 있다(단, 이번 세션 실측으로는 이게 항상 처리량을 늘려주진 않았다 — [BMT](starrocks-bmt.md) "4라운드" 참고).
