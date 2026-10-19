#!/bin/bash
# DAG 저장소(GitLab 프로젝트)의 브랜치 규칙을 적용한다.
#  - main : 직접 푸시 금지, 병합은 Maintainer만, 파이프라인이 성공해야 병합된다.
#  - develop : 상시 브랜치(삭제 불가). Developer 이상이 푸시할 수 있다.
#  - 기본 브랜치는 develop, 병합 후 소스 브랜치는 지우지 않는다(develop 삭제 방지).
# 프로젝트와 두 브랜치는 미리 있어야 한다(push-to-create 로 만들어 푸시해 둔다).
#
# 사용법: ./05-protect-dags-repo.sh [프로젝트 경로]   기본값: chan/airflow-dags

set -euo pipefail

PROJECT="${1:-chan/airflow-dags}"
OWNER="${PROJECT%%/*}"

kubectl -n gitlab exec deploy/gitlab -- env PROJECT="$PROJECT" OWNER="$OWNER" gitlab-rails runner '
p = Project.find_by_full_path(ENV["PROJECT"])
u = User.find_by_username(ENV["OWNER"])

p.update!(only_allow_merge_if_pipeline_succeeds: true, remove_source_branch_after_merge: false)

# main: 푸시 권한 없음(0), 병합은 Maintainer(40)
pb = p.protected_branches.find_by(name: "main")
pb.push_access_levels.update_all(access_level: 0)

# develop: 푸시 Developer(30), 병합 Maintainer(40), 강제 푸시 금지
unless p.protected_branches.exists?(name: "develop")
  ProtectedBranches::CreateService.new(p, u, name: "develop",
    push_access_levels_attributes: [{access_level: Gitlab::Access::DEVELOPER}],
    merge_access_levels_attributes: [{access_level: Gitlab::Access::MAINTAINER}],
    allow_force_push: false).execute
end

p.change_head("develop")

p.reload
puts "default=#{p.default_branch} merge_if_pipeline_ok=#{p.only_allow_merge_if_pipeline_succeeds}"
p.protected_branches.each { |b| puts "#{b.name} push=#{b.push_access_levels.map(&:access_level)} merge=#{b.merge_access_levels.map(&:access_level)} force=#{b.allow_force_push}" }'
