#!/usr/bin/env python3
"""StarRocks 어플리케이션 샘플 — pymysql로 접속해 테이블 생성/적재/조회하는 최소 예시.

사전 조건: pip install pymysql
           클러스터 밖(예: 로컬 Mac)에서 실행하려면 먼저 포트포워딩:
             kubectl -n starrocks port-forward svc/fe 9030:9030
           클러스터 안(같은 k8s 네임스페이스)에서 실행하면 host를
           fe.starrocks.svc.cluster.local 로 바꾸면 된다.

이 스크립트는 실행 후 만든 테이블/DB를 스스로 정리한다 — 반복 실행 가능.
"""
import pymysql

HOST = "127.0.0.1"  # 포트포워딩 사용 시. 클러스터 내부라면 fe.starrocks.svc.cluster.local
PORT = 9030

conn = pymysql.connect(host=HOST, port=PORT, user="root", password="", autocommit=True)
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
