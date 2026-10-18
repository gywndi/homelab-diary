#!/bin/bash
# 셀프 회원가입을 끈다. GitLab이 인터넷에 공개돼 있어서, 아무나 계정을 만들 수 없게 막는다.
# 이후 계정은 관리자가 Admin > Users에서 직접 만든다.
#
# 사용법: ./04-disable-signup.sh

set -euo pipefail

kubectl -n gitlab exec deploy/gitlab -- gitlab-rails runner \
  'ApplicationSetting.current.update!(signup_enabled: false); puts "signup_enabled=#{ApplicationSetting.current.signup_enabled}"'
