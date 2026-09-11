# LLM 서빙 (Ollama + RAG)

[← 이전: Vault](11-vault.md)

llm001의 GPU를 실제 워크로드로 써본다. Ollama로 로컬 LLM(Qwen2.5:7B)을 서빙하고, 그 위에 RAG(Retrieval-Augmented Generation, 검색 증강 생성) — 내가 저장한 문서를 근거로 질문에 답하는 구조 — 를 얹었다. 지금은 클러스터 내부용으로만 검증했고, 외부 공개(인증·도메인)는 별도로 진행한다.

## RAG가 하는 일 (개념)

**모델을 다시 학습시키는 대신, 질문할 때마다 관련 자료를 찾아서 같이 보여주고 그걸 보고 답하게 시키는 방식**이다. 오픈북 시험에 비유하면 쉽다 — 책을 통째로 암기시키는 대신(=모델 재학습, 비싸고 느림), 시험 볼 때 관련 페이지만 펼쳐주는 것(=RAG, 자료가 바뀌면 그 페이지만 바꾸면 됨)이다.

두 단계로 나뉜다:
1. **저장(`POST /documents`, 문서 넣을 때 한 번만)**: 문서를 작은 조각(청크)으로 자른다 → 각 조각을 임베딩 모델로 "의미를 담은 숫자 목록(벡터)"으로 바꾼다 → {원문, 벡터}를 벡터DB에 저장해둔다.
2. **질문(`POST /ask`, 매번)**: 질문도 똑같이 벡터로 바꾼다 → 벡터DB에서 "의미가 가장 비슷한 조각"을 찾는다(단어가 달라도 뜻이 비슷하면 찾아진다) → 찾은 조각을 "이거 참고해서 답해"라는 프롬프트에 끼워 넣어 LLM에 넘긴다 → LLM은 그 내용을 읽고 답만 만든다.

이 문서에서 저장 단계의 "문서"는 두 가지 방식으로 채웠다 — 사람이 직접 텍스트를 넣는 방식과, 웹 검색으로 자동 수집하는 방식(아래 "커피 지식 수집" 참고).

## 목적

GPU 노드([`05-llm-gpu-node.md`](05-llm-gpu-node.md)로 스케줄링 가능하게 만들어둔 것) 위에서 실제로 의미 있는 워크로드를 돌려본다. 단순 챗봇이 아니라, 저장해둔 문서에 없는 내용은 "모른다"고 답하고 있는 내용은 정확히 찾아 답하는 것까지 실측으로 확인한다.

## 대상

| 컴포넌트 | 배치 | 스토리지 |
|---|---|---|
| Ollama(Qwen2.5:7B, nomic-embed-text) | llm001(GPU 요청으로 자동 스케줄) | PVC 50Gi(`nfs-nas`) |
| RAG 앱(FastAPI + ChromaDB) | 아무 노드(GPU 불필요, Ollama를 네트워크로 호출) | PVC 2Gi(`ceph-csi-rbd`) |
| SearXNG(자체 호스팅 메타검색엔진) | 아무 노드(GPU 불필요) | 없음(상태 없는 검색 프록시) |

## 스크립트 목록 (이름 순)

### Ollama 배포
- 설명: `llm` 네임스페이스, GPU를 요청하는 Deployment(1 replica), 모델 저장용 PVC, 내부 전용 Service(11434)를 만든다. `nodeSelector` 없이 `resources.limits.nvidia.com/gpu: 1`만으로 스케줄러가 llm001을 자동으로 고른다 — GPU 리소스를 실제로 가진 노드가 거기뿐이라서다([`05-llm-gpu-node.md`](05-llm-gpu-node.md) 설계 결정 참고).
- 스크립트: [`01-deploy-ollama.sh`](../scripts/12-llm-serving/01-deploy-ollama.sh)
```bash
./01-deploy-ollama.sh
```
모델은 배포 후 별도로 pull한다(이미지에 안 들어있음, 처음 실행 시 받아야 함):
```bash
kubectl -n llm exec deploy/ollama -- ollama pull qwen2.5:7b
kubectl -n llm exec deploy/ollama -- ollama pull nomic-embed-text
```

### RAG 앱 배포
- 설명: 문서를 저장하면 청크로 쪼개 Ollama 임베딩 모델로 벡터화해 ChromaDB(내장형, 별도 서버 없이 파일로 영속화)에 저장한다. 질문이 오면 같은 방식으로 벡터화해서 유사한 청크를 찾고, 그 내용을 컨텍스트로 Qwen2.5에 넘겨 답을 생성한다. 커스텀 이미지를 안 만들고 `python:3.12-slim`에 컨테이너 시작 시점에 `pip install`하는 방식이라 첫 기동이 느리다(수 분) — 코드는 ConfigMap으로 마운트한다.
- 스크립트: [`02-deploy-rag-app.sh`](../scripts/12-llm-serving/02-deploy-rag-app.sh), 앱 코드: [`rag-app.py`](../scripts/12-llm-serving/rag-app.py)
```bash
./02-deploy-rag-app.sh
```
핵심 부분(`rag-app.py`):
```python
def embed(text: str):
    r = requests.post(f"{OLLAMA_URL}/api/embeddings",
                       json={"model": EMBED_MODEL, "prompt": text}, timeout=60)
    return r.json()["embedding"]

@app.post("/documents")
def add_document(doc: Document):
    chunks = chunk_text(doc.text)                      # 500자 단위, 50자 겹침
    embeddings = [embed(c) for c in chunks]
    collection.upsert(ids=..., embeddings=embeddings, documents=chunks, ...)

@app.post("/ask")
def ask(q: Question):
    q_emb = embed(q.question)
    results = collection.query(query_embeddings=[q_emb], n_results=q.top_k)
    context = "\n\n".join(results["documents"][0])
    prompt = f"다음 문서 내용을 참고해서 질문에 답해라. 문서에 없는 내용이면 모른다고 답해라.\n\n[문서]\n{context}\n\n[질문]\n{q.question}\n\n[답변]"
    r = requests.post(f"{OLLAMA_URL}/api/generate",
                       json={"model": GEN_MODEL, "prompt": prompt, "stream": False}, timeout=120)
    return {"answer": r.json()["response"], "sources": results["documents"][0]}
```

### 웹 검색(SearXNG) 배포
- 설명: Google/Bing/DuckDuckGo 등 여러 검색엔진 결과를 API 키 없이 JSON으로 모아주는 자체 호스팅 메타검색엔진이다. 문서 수집 스크립트가 이걸로 검색 결과 URL 목록을 받아온다. 상태 없는 검색 프록시라 PVC가 필요 없다.
- 스크립트: [`03-deploy-searxng.sh`](../scripts/12-llm-serving/03-deploy-searxng.sh)
```bash
./03-deploy-searxng.sh
```
핵심 부분 — 기본 설정은 JSON 응답 포맷이 꺼져 있어서 명시적으로 켜야 한다:
```yaml
search:
  formats:
    - html
    - json
```

### 커피 지식 수집
- 설명: 바리스타/커피 상식 주제 5개(기초 지식, 에스프레소 추출, 로스팅 단계, 핸드드립, 라떼아트)를 SearXNG로 검색 → 상위 2개 페이지씩 실제 접속해서 본문 텍스트만 추출(HTML 태그 제거) → RAG 앱의 `POST /documents`로 저장한다. 이 스크립트 자체는 임베딩/청크 분할을 안 한다 — "본문 텍스트를 모아서 RAG 앱에 전달"까지만 하고, 나머지는 RAG 앱(`rag-app.py`)이 알아서 한다.
- 스크립트: [`collect-coffee-knowledge.py`](../scripts/12-llm-serving/collect-coffee-knowledge.py)
```bash
kubectl -n llm port-forward svc/searxng 8080:8080 &
kubectl -n llm port-forward svc/rag-app 8000:8000 &
python3 collect-coffee-knowledge.py
```
핵심 부분:
```python
def search(query: str):
    r = requests.get(f"{SEARXNG_URL}/search", params={"q": query, "format": "json"}, timeout=30)
    return r.json().get("results", [])

def fetch_page_text(url: str) -> str:
    r = requests.get(url, timeout=10, headers={"User-Agent": "Mozilla/5.0"})
    return extract_text(r.text)          # HTML 태그 제거, 본문만 추출

def store_document(doc_id: str, text: str):
    return requests.post(f"{RAG_URL}/documents", json={"id": doc_id, "text": text}, timeout=120).json()
```

## 설계 결정

- **Ollama를 선택.** vLLM 같은 고성능 서빙 엔진도 있지만, "간단한 질문 대응"이라는 목표엔 과하다. 컨테이너 하나로 뜨고 모델을 API 호출로 바로 받아 쓸 수 있어서 진입 장벽이 가장 낮다.
- **모델 저장은 NAS(`nfs-nas`), 벡터DB는 Ceph RBD(`ceph-csi-rbd`) — 같은 "스토리지"라도 용도별로 나눴다.** 모델 가중치는 한 번 받으면 거의 안 바뀌는 대용량 정적 파일이라 NAS가 맞다. 반면 RAG 벡터DB(ChromaDB)는 내부적으로 SQLite를 쓰는데, SQLite는 파일 잠금이 제대로 안 되는 네트워크 스토리지에서 손상 위험이 있다고 공식적으로 경고한다 — 이 NAS는 `nolock`(NFSv3, [`10-nas-storage.md`](10-nas-storage.md) 알려진 이슈)으로 구성돼 있어서 그 위험이 실제로 존재한다. 그래서 벡터DB만 진짜 블록 디바이스인 RBD로 뺐다.
- **두 Deployment 모두 `strategy: Recreate`.** 둘 다 RWO(ReadWriteOnce) 볼륨을 쓰는데, 기본 RollingUpdate 전략은 "새 파드 먼저 → 기존 파드 나중"이라 새 파드가 볼륨을 못 붙이고 무한 대기한다(아래 "알려진 이슈" 참고). "기존 파드를 먼저 내리고 새로 올리는" Recreate로 바꿔서 해결했다.
- **RAG 앱은 커스텀 이미지를 안 만들고 `python:3.12-slim` + 컨테이너 시작 시 `pip install`.** 이 저장소에 컨테이너 이미지 빌드/레지스트리 파이프라인이 아직 없다 — 시범 구성 단계라 재기동 때마다 의존성을 새로 받는 비용(수 분)을 감수하는 쪽을 택했다. 정식으로 쓸 거면 이미지를 미리 빌드해두는 게 맞다.
- **RAG 앱은 GPU를 직접 요청하지 않는다.** 실제 GPU 연산(임베딩/생성)은 전부 Ollama가 하고, RAG 앱은 그걸 네트워크로 호출만 하는 얇은 오케스트레이션 계층이라 아무 노드에나 뜨면 된다.
- **웹 검색은 외부 API(Google/Bing 유료 API, Tavily 등) 대신 SearXNG 자체 호스팅.** API 키·계정 발급이 필요 없고, 이 저장소가 지금까지 해온 방향(Ceph/Vault/Ollama 전부 자체 호스팅)과 일관된다. 여러 검색엔진 결과를 한 번에 모아주는 메타검색엔진이라 특정 엔진 하나에 종속되지도 않는다.
- **지식 수집은 "매 질문마다 실시간 검색"이 아니라 "한 번 모아서 저장".** 매번 웹 검색을 하면 응답이 느려지고 매번 같은 검색을 반복하는 낭비도 생긴다. 커피처럼 자주 안 바뀌는 상식성 지식은 미리 모아서 벡터DB에 넣어두는 쪽이 훨씬 빠르고 저렴하다 — 실시간 검색 연동(질문마다 웹도 같이 검색)은 뉴스처럼 계속 바뀌는 정보가 필요해지면 그때 추가한다.

## 알려진 이슈

### RWO 볼륨 + 기본 RollingUpdate 전략은 데드락에 걸린다
Deployment 기본 전략(RollingUpdate)으로 RWO PVC를 쓰는 파드를 재배포하면, 새 파드가 기존 파드가 아직 붙잡고 있는 볼륨을 못 붙여서 `FailedAttachVolume`으로 계속 대기한다 — replica 1개짜리 워크로드에서 롤링 업데이트 자체가 의미 없으니, `strategy: Recreate`로 바꾸는 게 정답이다.

### ChromaDB의 텔레메트리 전송 에러는 무해하다
로그에 `Failed to send telemetry event ... capture() takes 1 positional argument but 3 were given`가 뜨는데, ChromaDB가 사용량을 자기 서버로 보내려다 실패하는 것뿐이다(버전 간 API 불일치). 기능에는 영향 없다.

### 커스텀 이미지가 없어 pip install에 수 분씩 걸린다
`chromadb`가 의존성이 많아서(k8s 클라이언트 라이브러리까지 딸려옴) 첫 기동 때마다 수 분이 걸린다. readinessProbe(`/health`)를 걸어뒀기 때문에 이 기간엔 파드가 Ready로 안 잡히는 게 정상이다 — readinessProbe 없이는 k8s가 "컨테이너 실행 중 = Ready"로 오판해서 rollout이 실제 앱 준비 전에 성급하게 성공 처리된다.

## 검증 명령

```bash
# 파드 상태
kubectl -n llm get pods -o wide

# 모델 목록 확인
kubectl -n llm exec deploy/ollama -- ollama list

# 문서 저장 (port-forward 후)
kubectl -n llm port-forward svc/rag-app 8000:8000 &
curl -X POST http://127.0.0.1:8000/documents -H 'Content-Type: application/json' \
  -d '{"id": "test", "text": "저장할 문서 내용"}'

# 질문
curl -X POST http://127.0.0.1:8000/ask -H 'Content-Type: application/json' \
  -d '{"question": "문서 내용에 대한 질문"}'
```

## 검증 이력

2026-09-11 end-to-end 검증 완료:
1. GPU 인식 확인(`RTX 5060 Ti, 16GB VRAM` — Ollama 로그의 `inference compute` 항목)
2. 문서 저장 → 질문 시 문서에 있는 내용(GPU 모델명, VRAM 용량)을 정확히 찾아 답변하는 것 확인
3. 문서에 없는 내용(서울 지하철 노선)을 물으면 "문서에 없다"고 답하고 지어내지 않는 것 확인
4. RWO+RollingUpdate 데드락을 실제로 재현(`FailedAttachVolume`) → `strategy: Recreate`로 수정 후 재배포해 해결 확인
5. **응답 속도 실측**: 콜드스타트(모델이 GPU 메모리에서 내려간 상태의 첫 호출) 약 1.7~2초, 웜업된 임베딩 8~10ms, 순수 생성 처리량 89.4 tokens/sec, 실제 RAG 답변(임베딩+검색+생성) 1건에 약 2초
6. **웹 검색 기반 지식 수집**: SearXNG로 바리스타/커피 주제 5개 검색 → 상위 10개 페이지 본문 수집(실패 0건) → 116개 청크로 저장 → "에스프레소 추출 요소", "로스팅 단계"를 질문해 실제 수집된 내용(1차/2차 크랙 등 전문 용어 포함) 기반으로 정확히 답변하는 것 확인

---

[← 이전: Vault](11-vault.md)
