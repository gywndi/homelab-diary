#!/bin/bash
# CephFS 볼륨 생성 — 로그 적재(RWX, 실시간 append) 용도.
# ceph fs volume create가 메타데이터/데이터 풀 생성 + MDS 배치를 한 번에 처리한다.
#
# 사용법: chan08에서 실행
#   sudo ./22-cephadm-cephfs.sh <fs 이름> <MDS 배치 노드 목록, 콤마 구분>
#   예: sudo ./22-cephadm-cephfs.sh logfs chan08,chan09,llm001

set -euo pipefail

FSNAME="${1:-}"
PLACEMENT="${2:-}"
if [[ -z "$FSNAME" || -z "$PLACEMENT" ]]; then
  echo "사용법: $0 <fs 이름> <MDS 배치 노드 목록, 콤마 구분>" >&2
  exit 1
fi

echo "== CephFS 볼륨 생성 (메타데이터/데이터 풀 + MDS 자동 배치) =="
cephadm shell -- ceph fs volume create "$FSNAME" --placement="$PLACEMENT"

echo "== MDS 캐시 한도 1GB로 설정 (로그 적재처럼 파일 수·메타데이터 부하가 적은 워크로드엔 충분) =="
cephadm shell -- ceph config set mds mds_cache_memory_limit 1073741824

echo "== 상태 확인 (MDS 기동 대기) =="
sleep 8
cephadm shell -- ceph fs status "$FSNAME"

echo "완료: ${FSNAME} 생성됨. 클라이언트 인증은 'ceph fs authorize' 참고(lessons/07-1-ceph-storage.md)"
