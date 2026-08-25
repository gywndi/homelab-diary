# Day 1 — 서버가 나를 알아보게 만들기

> [Homelab Diary](../README.md) 시리즈 · 대상 서버: chan08(10.5.5.8) · chan09(10.5.5.9) · OS: Ubuntu 24.04 LTS

새로 설치한 서버 두 대는 아무것도 모르는 상태였습니다. SSH로 겨우 붙을 수는 있어도 sudo를 쓰려면 매번 비밀번호를 물었고, 방화벽이 열려 있는지 막혀 있는지도 확인이 안 됐습니다. 사람이 상주하지 않는 서버를 스크립트로 계속 다루려면 이 장벽부터 걷어내야 했습니다.

먼저 확인한 건 SSH 키 인증이었습니다. `ssh -o BatchMode=yes`로 붙여서 비밀번호를 안 물어보면 통과 — 근데 sudo는 별개였습니다. 자동화 스크립트 안에 비밀번호를 넣을 수는 없으니, `bootstrap-sudoers.sh`를 손으로 딱 한 번 돌려서 `/etc/sudoers.d/90-chan-nopasswd`에 `chan ALL=(ALL) NOPASSWD:ALL`을 넣었습니다. 사람이 직접 개입해야 하는 유일한 단계고, 이후로는 전부 원격에서 스크립트로 끝낼 수 있습니다.

여기서부터는 순서대로 스크립트를 돌리면 됩니다. `02-system-update.sh`가 `apt-get dist-upgrade`로 커널까지 포함해서 싹 올리고, `03-timezone.sh`가 `timedatectl set-timezone Asia/Seoul`로 시간대를 맞추고 chrony를 켭니다. `04-firewall.sh`는 방화벽 기본값을 "인바운드 전부 차단"으로 세팅한 뒤 `ufw allow from 10.5.5.0/24 to any port 22`로 내부망 SSH만 열어둡니다. 마지막은 `01-format-mount-data.sh` — 놀고 있던 1TB 디스크를 보니 이미 XFS로 포맷은 돼 있는데 마운트만 안 된 상태였습니다. `mkfs.xfs -f`로 새로 밀고 UUID를 뽑아서 `/etc/fstab`에 등록해 `/data`로 고정했습니다. 앞으로 MySQL 데이터도, 가상머신 디스크도 전부 이 안에 쌓일 자리입니다.

전체 실행 순서와 각 스크립트가 정확히 뭘 건드리는지는 [`scripts/provision/`](../scripts/provision/README.md)에 정리해뒀습니다.

---
◀ [시리즈 목차](../README.md) · [Day 2 — 방화벽 재정리](day2-firewall.md) ▶
