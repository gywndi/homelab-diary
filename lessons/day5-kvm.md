# Day 5 — KVM, 언제든 VM을 띄울 수 있는 상태 만들기

> [Homelab Diary](../README.md) 시리즈

Kubernetes로 옮기기 애매한 워크로드, 이를테면 특정 OS가 필요하거나 컨테이너화가 안 되는 소프트웨어를 위한 비상구를 하나 만들어뒀습니다. 지금 당장 띄울 VM은 없어서, 실제로 VM을 만드는 대신 "필요할 때 바로 만들 수 있는 상태"까지만 준비했습니다.

[`scripts/kvm/01-setup-libvirt.sh`](../scripts/kvm/01-setup-libvirt.sh) 하나로 끝나는 작업입니다. qemu-kvm과 libvirt를 깔고, 작업 계정을 `libvirt`·`kvm` 그룹에 넣어 sudo 없이 virsh를 쓸 수 있게 하고, `virsh pool-define-as data-pool dir --target /data/vms`로 `/data` 밑에 VM 전용 저장 공간을 등록합니다.

여기서 사소하게 헷갈린 게 하나 있었습니다. 분명 저장 공간을 만들었는데 확인 명령을 치면 아무것도 안 보이는 겁니다. 이유는 간단했습니다 — 관리자 권한으로 만든 풀은 시스템 전체가 쓰는 영역(`qemu:///system`)에 등록되는데, 일반 계정으로 그냥 확인하면 그 계정만의 영역(`qemu:///session`)을 기본으로 봅니다. 데이터가 사라진 게 아니라 서로 다른 곳을 보고 있었던 것뿐이었고, `~/.config/libvirt/libvirt.conf`에 `uri_default = "qemu:///system"` 한 줄을 넣어 이 계정의 기본 대상을 고정했습니다.

## Day 1~5를 마치고

서버 두 대로 Kubernetes 클러스터, MySQL 이중화, KVM 기반까지 다 만들고 장애 상황까지 재현해서 검증했습니다. 중간에 걸렸던 두 문제 — 방화벽이 파드 통신을 막았던 것, 주석 처리된 설정 줄 때문에 datadir 변경이 조용히 실패했던 것 — 둘 다 증상과 원인이 한 걸음 떨어져 있었다는 공통점이 있네요. 로그를 끝까지 읽고 거슬러 올라가는 게 결국 제일 빠른 길이었습니다.

다음 화부터는 장비가 늘어나는 대로 이어집니다. 새 노드가 들어오면 역할에 맞춰 클러스터에 합류시키거나, 필요하면 독립 서버로 따로 운영할 계획입니다.

---
◀ [Day 4 — MySQL 이중화](day4-mysql-ha.md) · [시리즈 목차](../README.md)
