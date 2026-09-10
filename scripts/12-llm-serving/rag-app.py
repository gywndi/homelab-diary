import os
import requests
import chromadb
from fastapi import FastAPI
from pydantic import BaseModel

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://ollama.llm.svc.cluster.local:11434")
GEN_MODEL = os.environ.get("GEN_MODEL", "qwen2.5:7b")
EMBED_MODEL = os.environ.get("EMBED_MODEL", "nomic-embed-text")
CHUNK_SIZE = 500
CHUNK_OVERLAP = 50

app = FastAPI()
client = chromadb.PersistentClient(path="/data/chroma")
collection = client.get_or_create_collection("documents")


class Document(BaseModel):
    id: str
    text: str


class Question(BaseModel):
    question: str
    top_k: int = 3


def embed(text: str):
    r = requests.post(
        f"{OLLAMA_URL}/api/embeddings",
        json={"model": EMBED_MODEL, "prompt": text},
        timeout=60,
    )
    r.raise_for_status()
    return r.json()["embedding"]


def chunk_text(text: str):
    chunks = []
    start = 0
    while start < len(text):
        end = start + CHUNK_SIZE
        chunks.append(text[start:end])
        if end >= len(text):
            break
        start = end - CHUNK_OVERLAP
    return chunks


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/documents")
def add_document(doc: Document):
    chunks = chunk_text(doc.text)
    ids = [f"{doc.id}-{i}" for i in range(len(chunks))]
    embeddings = [embed(c) for c in chunks]
    metadatas = [{"doc_id": doc.id, "chunk_index": i} for i in range(len(chunks))]
    collection.upsert(ids=ids, embeddings=embeddings, documents=chunks, metadatas=metadatas)
    return {"stored_chunks": len(chunks)}


@app.post("/ask")
def ask(q: Question):
    q_emb = embed(q.question)
    results = collection.query(query_embeddings=[q_emb], n_results=q.top_k)
    context_chunks = results["documents"][0] if results["documents"] else []
    context = "\n\n".join(context_chunks)
    prompt = f"""다음 문서 내용을 참고해서 질문에 답해라. 문서에 없는 내용이면 모른다고 답해라.

[문서]
{context}

[질문]
{q.question}

[답변]"""
    r = requests.post(
        f"{OLLAMA_URL}/api/generate",
        json={"model": GEN_MODEL, "prompt": prompt, "stream": False},
        timeout=120,
    )
    r.raise_for_status()
    return {"answer": r.json()["response"], "sources": context_chunks}
