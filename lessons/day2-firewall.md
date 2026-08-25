# Day 2 — 방화벽, 미리 막고 필요한 것만 열기

> [Homelab Diary](../README.md) 시리즈

원칙은 단순했습니다. 일단 다 막고, 진짜 쓰는 것만 하나씩 연다. 어차피 내부망(10.5.5.0/24) 밖에서 이 서버들에 접근할 일은 없었으니까요.

문제는 방화벽을 처음 짤 때는 Kubernetes에 어떤 CNI를 쓸지도 안 정해진 상태였다는 겁니다. 그래서 후보였던 Flannel과 Calico 포트를 일단 다 열어뒀다가, Flannel로 확정되자 `ufw delete allow`로 Calico용 포트(179/tcp, VXLAN 4789/udp)를 다시 닫았습니다. MySQL과 keepalived를 붙일 때도 마찬가지로, 그 시점에야 3306과 VRRP를 열었습니다. 방화벽 규칙은 한 번 짜고 끝나는 게 아니라 결정이 바뀔 때마다 같이 손봐줘야 하더군요.

이 정리를 담은 게 [`scripts/provision/05-firewall-stage1.sh`](../scripts/provision/05-firewall-stage1.sh)입니다. 핵심은 `ufw allow ... port 3306`(MySQL)과 `ufw allow ... proto vrrp`(keepalived 헬스체크 신호) 두 줄을 추가하고, 안 쓰기로 한 Calico 포트를 지우는 것. Day 1의 초기 방화벽(`04-firewall.sh`) 위에 얹어서 적용됩니다.

---
◀ [Day 1 — 서버 기본 준비](day1-base-provisioning.md) · [시리즈 목차](../README.md) · [Day 3 — Kubernetes](day3-kubernetes.md) ▶
