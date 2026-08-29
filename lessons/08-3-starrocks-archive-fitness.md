# StarRocks를 MySQL 콜드 데이터 장기보관처로 쓸 수 있는가

배경은 [StarRocks 분석 엔진](08-1-starrocks-analytics.md), 클러스터 성능 확장 검증은 [BMT](08-2-starrocks-analytics-bmt.md) 참고.

## 배경

MySQL 샤딩 DB에 쌓인 오래된(콜드) 데이터를 StarRocks로 옮겨 "장기보관 DB" 역할을 맡길 수 있는지 검증했다. 트랜잭션 처리는 필요 없다. **압축(저장 비용)**과 **리스트/검색 조회(조회 편의성)** 두 가지가 핵심 요구사항이라 이 관점으로만 좁혀서 실측했다.

## 핵심 결론

압축률·리스트 조회·`COUNT(*)`·`LIKE` 검색 전부 실사용 가능한 수준이다. 단 설계 규칙 3가지를 지켜야 한다.

| 규칙 | 이유 |
|---|---|
| 압축은 `ZSTD`로(기본값 `LZ4` 아님) | 쓰기 빈도 낮은 아카이브엔 압축률이 더 중요. 쓰기 35% 느려지는 대신 저장공간 40% 절약 |
| 페이지네이션은 커서(keyset — "마지막으로 본 항목 다음부터" 방식) 방식으로, `OFFSET` 금지 | `OFFSET`은 깊은 페이지에서 최대 21배까지 느려짐(아래 실측) |
| 긴 텍스트 컬럼 `LIKE '%keyword%'` 전체 스캔 검색은 선택적 필터와 함께 쓰거나 역색인 검토 | 인덱스가 없어 테이블 크기에 비례해 느려짐 |

## 테스트 환경

- 클러스터: 홈랩 shared-data StarRocks(FE+CN, RGW 오브젝트 스토리지 기반), `replication_num=1`
- 데이터: 로그성 이벤트 500만 행, 현실적인 로우 구조로 생성

```sql
CREATE TABLE archive_logs (
  id BIGINT,
  user_id BIGINT,
  event_type VARCHAR(20),      -- login/logout/purchase/view/click/error/api_call/update_profile 8종
  created_at DATETIME,
  payload VARCHAR(500)         -- JSON형 텍스트, 8개 키(session_id/ip/user_agent 등)
) DUPLICATE KEY(id)
DISTRIBUTED BY HASH(id) BUCKETS 8
PROPERTIES("compression"="ZSTD");
```

원본(비압축) 크기는 896.6MB(TSV)다. STREAM LOAD로 적재했다(~11~16초). `user_id`는 1~100,000 균등 랜덤이다. `payload`의 각 필드값은 `val_a`/`val_b`/`val_c`/난수 중 랜덤 선택이다(적당히 반복되는 값이라 압축이 걸림 — 실제 로그 데이터와 유사).

## 1. 압축률: LZ4(기본값) vs ZSTD

```sql
-- 기본값(LZ4)과 비교하려면 같은 스키마를 압축 옵션만 바꿔 하나 더 생성
CREATE TABLE archive_logs_zstd (...동일 스키마...)
PROPERTIES("compression"="ZSTD");

-- 적재 후 실제 저장 크기 확인(USE <db>; 상태에서 실행)
SHOW DATA;
```

| 압축 방식 | 적재 시간 | 저장 크기 | 원본 대비 압축률 |
|---|---|---|---|
| LZ4(기본값) | 11.6초 | 213.9 MB | 약 4.0배 (855MB→214MB) |
| **ZSTD** | 15.6초(+35%) | **127.8 MB** | 약 **6.7배** (855MB→128MB) |

ZSTD가 LZ4보다 저장공간을 40% 더 아낀다. 아카이브는 "한 번 쓰고 오래 보관, 가끔 조회"하는 워크로드다. 쓰기 비용(+35%)보다 저장 비용 절감이 훨씬 중요하다. **아카이브 테이블은 `PROPERTIES("compression"="ZSTD")`로 만들 것.**

## 2. 리스트 조회(페이지네이션): 커서 vs OFFSET

같은 500만 행에서 "몇 번째 페이지로 바로 이동" 상황을 흉내 냈다.

```sql
-- 오프셋 방식: "N번째 페이지"를 직접 지정
SELECT id, user_id, event_type, created_at
FROM archive_logs
ORDER BY id
LIMIT 50 OFFSET 1000000;

-- 커서(keyset) 방식: "마지막으로 본 항목의 id 다음부터"
SELECT id, user_id, event_type, created_at
FROM archive_logs
WHERE id > :last_seen_id     -- 이전 페이지 마지막 행의 id
ORDER BY id
LIMIT 50;
```

| 방식 | 조건 | 지연시간 |
|---|---|---|
| 커서(초반) | `WHERE id > 1,000` | 34ms |
| 커서(중반) | `WHERE id > 2,500,000` | 30ms |
| 커서(후반) | `WHERE id > 4,900,000` | 31ms |
| OFFSET | `OFFSET 0` | 33ms |
| OFFSET | `OFFSET 100,000` | 103ms |
| OFFSET | `OFFSET 1,000,000` | 116ms |
| OFFSET | `OFFSET 4,900,000`(테이블 끝 근처) | **526ms** |

커서는 위치와 무관하게 항상 ~30ms다. OFFSET은 깊이에 비례해 계속 느려진다. 테이블 끝 근처에서는 초반 대비 16배(33ms→526ms) 느리다 — DB가 "OFFSET개를 읽고 버리는" 방식으로 처리하기 때문이다. **`LIMIT N, M`(=`LIMIT M OFFSET N`) 문법으로 페이지 번호 이동 UI를 만드는 건 대용량에서 피할 것.**

## 3. `COUNT(*)` — 페이지 번호 UI에 필요한 전체 개수, 문제 되는가

페이지 번호 이동 UI("1 2 3 ... 47")를 만들려면 전체 개수가 필요해서 `COUNT(*)`가 같이 붙는다. row-store(MySQL 등)에서는 이게 흔한 병목이다. 컬럼형인 StarRocks는 어떤지 확인했다.

```sql
SELECT COUNT(*) FROM archive_logs;                                     -- 전체
SELECT COUNT(*) FROM archive_logs WHERE user_id = 555;                 -- 고선택도 필터
SELECT COUNT(*) FROM archive_logs WHERE event_type = 'view';           -- 저선택도 필터(62.5만 건 매치)
SELECT COUNT(*) FROM archive_logs
  WHERE created_at BETWEEN '2023-11-01 00:00:00' AND '2023-12-01 00:00:00'; -- 날짜범위
```

| 쿼리 | 지연시간 | 결과 |
|---|---|---|
| `COUNT(*)` 전체 | 29~33ms | 5,000,000 |
| `WHERE user_id=555`(고선택도) | 46ms | 53 |
| `WHERE event_type='view'`(저선택도) | 59ms | 625,000 |
| `WHERE 날짜범위(1개월)` | 36ms | 453,333 |

필터 유무·선택도와 무관하게 전부 30~60ms대다. **이 규모에서 `COUNT(*)`는 병목이 아니다.** 컬럼형 스토리지라 세그먼트 메타데이터/벡터화 스캔만으로 답이 나온다. (단, 이번 세션에서 MySQL과 나란히 비교 측정은 하지 않았다 — "row-store는 느릴 것"이라는 일반 지식에 기댄 것이다.)

## 4. `LIKE` 검색 — 짧은 컬럼은 공짜, 긴 텍스트 컬럼은 매치 밀도에 좌우

```sql
-- 짧은 저카디널리티 컬럼(20자)
SELECT COUNT(*) FROM archive_logs WHERE event_type = 'purchase';   -- 등치(기준선)
SELECT COUNT(*) FROM archive_logs WHERE event_type LIKE 'pur%';    -- 앞쪽 와일드카드 없음
SELECT COUNT(*) FROM archive_logs WHERE event_type LIKE '%chase';  -- 뒤쪽
SELECT COUNT(*) FROM archive_logs WHERE event_type LIKE '%rcha%';  -- 양쪽

-- 긴 텍스트 컬럼(500자 JSON형)
SELECT COUNT(*) FROM archive_logs WHERE payload LIKE '%val_a%';               -- 고빈도(90% 매치)
SELECT COUNT(*) FROM archive_logs WHERE payload LIKE '%session_id%9999%';     -- 희귀(0.02% 매치)
SELECT COUNT(*) FROM archive_logs WHERE payload LIKE '%region":"val_c%';      -- 중간 밀도(25% 매치)
```

| 대상 컬럼 | 조건 | 매치 건수 | 지연시간 |
|---|---|---|---|
| `event_type`(20자) | `=` 등치(기준선) | 625,000 | 41ms |
| `event_type` | `LIKE 'pur%'` | 625,000 | 47ms |
| `event_type` | `LIKE '%chase'` | 625,000 | 43ms |
| `event_type` | `LIKE '%rcha%'` | 625,000 | 42ms |
| `payload`(500자) | `LIKE '%val_a%'`(고빈도) | 4,500,066 | **571ms** |
| `payload` | `LIKE '%region":"val_c%'`(중간) | 1,249,113 | 162ms |
| `payload` | `LIKE '%session_id%9999%'`(희귀) | 1,003 | 201ms |

짧은 컬럼은 `LIKE` 위치(앞/뒤/양쪽 `%`)와 무관하게 등치 조건과 차이 없다(41~47ms). 컬럼이 짧아 벡터화 스캔 자체가 원래 싸기 때문이다.

긴 컬럼은 인덱스가 없어 4~13배 비싸진다(160~570ms). 비용이 매치 건수에 단순 비례하지 않는다 — `COUNT(*)`는 매치 여부와 무관하게 5백만 행 전부를 평가해야 하기 때문이다.

`LIMIT`을 걸면 매치 밀도에 따라 결과가 완전히 갈린다.

```sql
-- 고빈도 패턴 + LIMIT: 매치가 흔해서 테이블 앞부분에서 바로 50건 채움
SELECT id FROM archive_logs WHERE payload LIKE '%val_a%' ORDER BY id LIMIT 50;
-- → 28ms (거의 공짜)

-- 희귀 패턴 + LIMIT: 50건 채우려면 사실상 테이블 전체를 훑어야 함
SELECT id FROM archive_logs WHERE payload LIKE '%session_id%9999%' ORDER BY id LIMIT 50;
-- → 213ms (필터 없는 기준선 19ms 대비 11배, COUNT(*)와 비슷한 비용)

-- 기존 선택적 필터와 결합하면 훨씬 싸짐
SELECT id, event_type FROM archive_logs
WHERE user_id = 555 AND payload LIKE '%val_a%'
ORDER BY id LIMIT 50;
-- → 68ms (user_id가 먼저 53건으로 좁혀놓고 그 위에서만 LIKE 평가)
```

짧은/저카디널리티 컬럼 검색은 자유롭게 써도 된다. 긴 텍스트 컬럼의 전체 스캔 `LIKE` 검색은 (1) 선택적 필터(사용자 ID, 날짜 범위 등)를 먼저 걸어 스캔 대상을 좁히거나, (2) StarRocks 역색인(inverted index — 텍스트 안의 단어를 미리 찾아두는 보조 인덱스) 도입을 검토해야 한다(이번엔 순수 `LIKE`만 봤고 역색인은 테스트 안 함).

## 5. `LIKE` 단독 검색 + 페이지네이션 — 실제 검색 API에 가장 가까운 시나리오

실제 검색창은 다른 필터 없이 키워드 하나만 받는 경우가 많다. 그 검색 결과를 다시 2페이지, 3페이지로 넘기면 `LIKE` 비용과 페이지네이션 비용이 같이 얹힌다.

```sql
-- OFFSET 방식으로 검색 결과 페이지 이동
SELECT id FROM archive_logs
WHERE payload LIKE '%val_a%'
ORDER BY id LIMIT 50 OFFSET 4000000;
```

| 패턴 | OFFSET | 지연시간 |
|---|---|---|
| 고빈도(90% 매치) | 0 | 68ms |
| 고빈도 | 1,000 | 310ms |
| 고빈도 | 100,000 | 515ms |
| 고빈도 | 1,000,000 | 510ms |
| 고빈도 | 4,000,000 | 611~936ms |
| 희귀(0.02%, 총 1,003건) | 0 | 227ms |
| 희귀 | 100 | 204ms |
| 희귀 | 500 | 174ms |
| 희귀 | 900 | 181ms |

일반 리스트 조회 때처럼 깊이에 깔끔하게 비례하지 않는다. 인덱스 없는 `LIKE` 자체가 이미 지배적 비용이라, 그 패턴의 "풀스캔에 가까운 비용" 근처로 금방 수렴하거나 아예 평평해진다.

여기서도 커서로 바꾸면 극적으로 빨라진다. `id`가 정렬 기준 컬럼이라 `WHERE id >= :cursor`로 스캔 시작점 자체를 건너뛸 수 있기 때문이다(별도 역색인 없이 얻는 이득).

```sql
-- 커서 방식: "이전 페이지 마지막 항목의 id부터" + LIKE
SELECT id FROM archive_logs
WHERE id >= :last_seen_id AND payload LIKE '%val_a%'
ORDER BY id LIMIT 50;
```

| 패턴 | 방식 | 지연시간 | 배율 |
|---|---|---|---|
| 희귀(offset 900 위치) | `OFFSET 900` | 214ms | 기준 |
| 희귀(같은 위치) | `WHERE id >= :cursor` | 109ms | **2배** |
| 고빈도(offset 400만 위치) | `OFFSET 4,000,000` | 936ms | 기준 |
| 고빈도(같은 위치) | `WHERE id >= :cursor` | 44ms | **21배** |

`LIKE`만 단독으로 걸리는 검색 API도 페이지네이션은 커서 방식(`WHERE id >= last_id AND payload LIKE ...`)으로 만들어야 한다. 최대 21배까지 차이 난다. 단 **첫 페이지 자체의 비용(인덱스 없는 전체/근접전체 스캔, 160~600ms대)은 커서로도 줄지 않는다** — 이건 선택적 필터나 역색인으로만 풀리는 별개의 문제다.

## 종합 결론

| 항목 | 결론 |
|---|---|
| 압축률 | ZSTD 기준 약 6.7배(855MB→128MB) — 실사용 가능 |
| 리스트 조회 | 커서 방식이면 항상 빠름(~30ms), OFFSET은 깊은 페이지에서 최대 16배 느림 |
| `COUNT(*)` | 필터 유무 무관 30~60ms대 — 이 규모에서 병목 아님 |
| 짧은 컬럼 `LIKE` | 등치 조건과 차이 없음 — 자유롭게 사용 |
| 긴 텍스트 컬럼 `LIKE` | 인덱스 없어 160~570ms(매치 밀도에 좌우) — 선택적 필터 병행 권장 |
| `LIKE` + 페이지네이션 | 커서 방식이면 최대 21배 빠름, 첫 페이지 비용은 그대로 |

**StarRocks는 MySQL 콜드 데이터의 장기보관처로 실사용 가능하다.** 압축은 ZSTD, 페이지네이션은 반드시 커서(keyset) 방식, 긴 텍스트 전체 스캔 검색은 선택적 필터를 곁들이거나 역색인을 검토하는 세 가지 규칙만 지키면 된다.

## 재현 방법

1. 500만 행 TSV 생성(node에서, `id, user_id, event_type, created_at_unix, payload` 순): 랜덤 시드 고정 파이썬 스크립트, 원본 크기 약 896.6MB.
2. 테이블 생성(위 DDL, `compression` 속성만 바꿔 LZ4/ZSTD 비교용으로 하나씩).
3. STREAM LOAD로 적재(공통 curl 패턴은 [StarRocks 분석 엔진](08-1-starrocks-analytics.md)의 STREAM LOAD 예시 참고) — 이 데이터셋 전용 옵션만 추가: `-H "column_separator:\t"`, `-H "columns: id,user_id,event_type,created_at_unix,payload,created_at=from_unixtime(created_at_unix)"`.
4. `SHOW DATA;`로 압축 후 저장 크기 확인. 위 쿼리들은 `SELECT NOW(6)` 감싸지 않고 클라이언트 벽시계 시간으로 측정했다(단발 실행, 반복 통계는 아직 안 냄).
