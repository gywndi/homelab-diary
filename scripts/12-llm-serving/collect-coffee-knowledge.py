"""
바리스타/커피 상식을 인터넷에서 수집해 RAG 벡터DB에 저장한다.

동작 순서 (주제 하나마다 반복):
  1. SearXNG(자체 호스팅 검색엔진)로 그 주제를 검색해서 관련 페이지 목록을 받는다
  2. 상위 몇 개 페이지에 실제로 접속해서 본문 텍스트만 뽑아낸다(광고/메뉴 등 제외)
  3. 그 본문을 RAG 앱의 POST /documents로 저장한다 (RAG 앱이 알아서 청크로 쪼개
     서 임베딩하고 벡터DB에 넣어준다 — 이 스크립트는 "본문 텍스트를 모아서
     전달"만 한다)

사용법: 로컬에서 두 개 다 port-forward 해두고 실행
  kubectl -n llm port-forward svc/searxng 8080:8080 &
  kubectl -n llm port-forward svc/rag-app 8000:8000 &
  python3 collect-coffee-knowledge.py
"""

import re
import requests
from html.parser import HTMLParser

SEARXNG_URL = "http://127.0.0.1:8080"
RAG_URL = "http://127.0.0.1:8000"
TOPICS = [
    "바리스타 기초 지식",
    "에스프레소 추출 원리",
    "커피 원두 로스팅 단계",
    "핸드드립 커피 추출법",
    "우유 스티밍 라떼아트 원리",
]
PAGES_PER_TOPIC = 2


class TextExtractor(HTMLParser):
    """스크립트/스타일 태그는 건너뛰고 본문 텍스트만 모은다."""

    def __init__(self):
        super().__init__()
        self.chunks = []
        self.skip = False

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style"):
            self.skip = True

    def handle_endtag(self, tag):
        if tag in ("script", "style"):
            self.skip = False

    def handle_data(self, data):
        if not self.skip:
            text = data.strip()
            if text:
                self.chunks.append(text)


def extract_text(html: str) -> str:
    parser = TextExtractor()
    parser.feed(html)
    text = " ".join(parser.chunks)
    return re.sub(r"\s+", " ", text).strip()


def search(query: str):
    r = requests.get(f"{SEARXNG_URL}/search", params={"q": query, "format": "json"}, timeout=30)
    r.raise_for_status()
    return r.json().get("results", [])


def fetch_page_text(url: str) -> str:
    try:
        r = requests.get(url, timeout=10, headers={"User-Agent": "Mozilla/5.0"})
        r.raise_for_status()
        return extract_text(r.text)
    except Exception as e:
        print(f"  실패({url}): {e}")
        return ""


def store_document(doc_id: str, text: str):
    r = requests.post(f"{RAG_URL}/documents", json={"id": doc_id, "text": text}, timeout=120)
    r.raise_for_status()
    return r.json()


def main():
    doc_index = 0
    for topic in TOPICS:
        print(f"\n=== 검색: {topic} ===")
        results = search(topic)
        for result in results[:PAGES_PER_TOPIC]:
            url = result["url"]
            title = result.get("title", url)
            print(f"- 수집: {title} ({url})")
            text = fetch_page_text(url)
            if len(text) < 200:
                print("  본문이 너무 짧아 건너뜀")
                continue
            text = text[:8000]  # 페이지 하나당 너무 길지 않게 제한
            doc_id = f"coffee-{doc_index}"
            resp = store_document(doc_id, text)
            print(f"  저장됨: {doc_id}, {resp['stored_chunks']}개 청크")
            doc_index += 1


if __name__ == "__main__":
    main()
