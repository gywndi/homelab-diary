# LLM 서빙 (Ollama + RAG)

[← 이전: Vault](11-vault.md)

llm001의 GPU를 실제 워크로드로 써본다. Ollama로 로컬 LLM(Qwen2.5:7B)을 서빙하고, 그 위에 RAG(Retrieval-Augmented Generation, 검색 증강 생성) — 내가 저장한 문서를 근거로 질문에 답하는 구조 — 를 얹었다. 지금은 클러스터 내부용으로만 검증했고, 외부 공개(인증·도메인)는 별도로 진행한다.

## 목적

GPU 노드([`05-llm-gpu-node.md`](05-llm-gpu-node.md)로 스케줄링 가능하게 만들어둔 것) 위에서 실제로 의미 있는 워크로드를 돌려본다. 단순 챗봇이 아니라, 저장해둔 문서에 없는 내용은 "모른다"고 답하고 있는 내용은 정확히 찾아 답하는 것까지 실측으로 확인한다.

## 대상

| 컴포넌트 | 배치 | 스토리지 |
|---|---|---|
| Ollama(Qwen2.5:7B, nomic-embed-text) | llm001(GPU 요청으로 자동 스케줄) | PVC 50Gi(`nfs-nas`) |
| RAG 앱(FastAPI + ChromaDB) | 아무 노드(GPU 불필요, Ollama를 네트워크로 호출) | PVC 2Gi(`ceph-csi-rbd`) |

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

## 설계 결정

- **Ollama를 선택.** vLLM 같은 고성능 서빙 엔진도 있지만, "간단한 질문 대응"이라는 목표엔 과하다. 컨테이너 하나로 뜨고 모델을 API 호출로 바로 받아 쓸 수 있어서 진입 장벽이 가장 낮다.
- **모델 저장은 NAS(`nfs-nas`), 벡터DB는 Ceph RBD(`ceph-csi-rbd`) — 같은 "스토리지"라도 용도별로 나눴다.** 모델 가중치는 한 번 받으면 거의 안 바뀌는 대용량 정적 파일이라 NAS가 맞다. 반면 RAG 벡터DB(ChromaDB)는 내부적으로 SQLite를 쓰는데, SQLite는 파일 잠금이 제대로 안 되는 네트워크 스토리지에서 손상 위험이 있다고 공식적으로 경고한다 — 이 NAS는 `nolock`(NFSv3, [`10-nas-storage.md`](10-nas-storage.md) 알려진 이슈)으로 구성돼 있어서 그 위험이 실제로 존재한다. 그래서 벡터DB만 진짜 블록 디바이스인 RBD로 뺐다.
- **두 Deployment 모두 `strategy: Recreate`.** 둘 다 RWO(ReadWriteOnce) 볼륨을 쓰는데, 기본 RollingUpdate 전략은 "새 파드 먼저 → 기존 파드 나중"이라 새 파드가 볼륨을 못 붙이고 무한 대기한다(아래 "알려진 이슈" 참고). "기존 파드를 먼저 내리고 새로 올리는" Recreate로 바꿔서 해결했다.
- **RAG 앱은 커스텀 이미지를 안 만들고 `python:3.12-slim` + 컨테이너 시작 시 `pip install`.** 이 저장소에 컨테이너 이미지 빌드/레지스트리 파이프라인이 아직 없다 — 시범 구성 단계라 재기동 때마다 의존성을 새로 받는 비용(수 분)을 감수하는 쪽을 택했다. 정식으로 쓸 거면 이미지를 미리 빌드해두는 게 맞다.
- **RAG 앱은 GPU를 직접 요청하지 않는다.** 실제 GPU 연산(임베딩/생성)은 전부 Ollama가 하고, RAG 앱은 그걸 네트워크로 호출만 하는 얇은 오케스트레이션 계층이라 아무 노드에나 뜨면 된다.

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

---

[← 이전: Vault](11-vault.md)
