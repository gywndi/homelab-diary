# Day 5 — KVM, 언제든 VM을 띄울 수 있는 상태 만들기

> [AI로 함께 만든 클러스터](../README.md) 시리즈

Kubernetes로 옮기기 애매한 워크로드, 이를테면 특정 운영체제가 필요하거나 컨테이너화가 안 되는 소프트웨어를 위한 비상구도 미리 만들어뒀습니다. 지금 당장 띄울 가상머신은 없었기 때문에, 실제 VM을 만드는 대신 "필요할 때 바로 만들 수 있는 상태"까지만 준비했습니다. KVM과 libvirt를 설치하고, `/data` 디스크 안에 가상머신 전용 저장 공간을 만들어 등록해뒀습니다.

## 사소하지만 헷갈렸던 점 — 분명 저장 공간을 만들었는데 확인 명령을 치면 아무것도 안 보였다

관리자 권한으로 만든 저장 공간은 시스템 전체가 함께 쓰는 영역(`qemu:///system`)에 등록되는데, 일반 계정으로 그냥 확인 명령을 실행하면 그 계정만 쓰는 별도의 영역(`qemu:///session`)을 기본으로 들여다봅니다. 데이터가 사라진 게 아니라 서로 다른 곳을 보고 있었던 것뿐이었습니다. chan 계정이 기본적으로 시스템 전체 영역을 보도록 설정을 하나 추가해서, 앞으로는 헷갈릴 일 없이 바로 확인할 수 있게 정리했습니다.

## 이 단계에서 쓴 명령어

- **`sudo apt-get install qemu-kvm libvirt-daemon-system libvirt-clients virtinst bridge-utils`** — 가상머신을 실제로 실행하는 하이퍼바이저(qemu-kvm)와 이를 관리하는 데몬(libvirt), 가상머신을 만들 때 쓰는 도구들을 설치합니다.
- **`sudo usermod -aG libvirt,kvm chan`** — chan 계정을 libvirt·kvm 그룹에 추가해서, 매번 `sudo`를 붙이지 않고도 가상머신을 관리할 수 있게 합니다.
- **`sudo systemctl enable --now libvirtd`** — 가상머신을 관리하는 핵심 데몬을 켜고, 서버가 재부팅돼도 자동으로 다시 켜지도록 등록합니다.
- **`virsh pool-define-as data-pool dir --target /data/vms`** — `/data/vms` 폴더를 "data-pool"이라는 이름의 저장 공간으로 libvirt에 등록합니다. 앞으로 만들 가상머신의 디스크 이미지는 전부 이 안에 저장됩니다.
- **`virsh pool-build data-pool` / `virsh pool-start data-pool` / `virsh pool-autostart data-pool`** — 등록한 저장 공간을 실제로 만들고(build), 사용 가능한 상태로 켜고(start), 서버가 재부팅돼도 자동으로 다시 켜지도록(autostart) 설정하는 세 단계입니다.
- **`echo 'uri_default = "qemu:///system"' > ~/.config/libvirt/libvirt.conf`** — 앞서 설명한 "저장 공간이 안 보이는" 문제의 해결책입니다. chan 계정이 `virsh` 명령을 실행할 때 기본적으로 바라보는 대상을 시스템 전체 영역으로 고정합니다.

## 이 레슨에서 쓴 스크립트

[`kvm/01-setup-libvirt.sh`](../kvm/01-setup-libvirt.sh) — 상세는 [`kvm/README.md`](../kvm/README.md) 참고.

## Day 1~5를 마치고

chan08과 chan09 두 대만으로 Kubernetes 클러스터, MySQL 이중화, KVM 기반까지 전부 완료하고, 실제로 장애 상황까지 재현해서 검증하는 데까지 왔습니다. 중간에 만난 두 번의 문제(방화벽이 파드 통신을 막았던 것, 주석 처리된 설정 줄 때문에 datadir 변경이 조용히 실패했던 것) 모두 겉으로 보이는 증상과 실제 원인이 한 걸음 떨어져 있었다는 공통점이 있습니다. 로그를 끝까지 읽고, 왜 그런 증상이 나오는지 거슬러 올라가는 과정이 결국 가장 확실한 지름길이었습니다.

다음 화부터는 장비가 늘어날 때마다 이어집니다. 메모리 8GB짜리 소형 노드가 들어오면 Kubernetes 워커로만 합류시키고, GPU 머신(16GB VRAM)과 Mac Studio(96GB)가 들어오면 클러스터에 넣지 않고 각각 독립된 LLM 추론 서버로 운영할 계획입니다. NAS가 연결되면 그때 클러스터의 공유 스토리지와 백업 대상으로 활용할 예정입니다. 자세한 로드맵은 [`specs/overview.md`](../specs/overview.md)에 있습니다.

---
◀ [Day 4 — MySQL 이중화](day4-mysql-ha.md) · [시리즈 목차](../README.md)
