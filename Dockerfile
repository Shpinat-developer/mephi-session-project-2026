FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LC_ALL=C.UTF-8

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        systemd systemd-sysv dbus dbus-user-session \
        sudo openssh-server \
        iproute2 iputils-ping net-tools \
        nano vim-tiny less curl wget \
        ca-certificates locales \
        rpm \
        network-manager \
        e2fsprogs parted util-linux kpartx \
        psmisc procps \
        bash-completion man-db \
        nginx tcpdump libcap2-bin \
        sshpass selinux-utils policycoreutils && \
    rm -rf /var/lib/apt/lists/*

# Прямое скачивание tcpdump.deb из Ubuntu-репозитория (для раздела 2.2).
# Делаем при сборке образа, чтобы при старте контейнера НЕ требовалось apt update.
# Архитектура определяется dpkg, URL ports.ubuntu.com работает для arm64 и amd64.
RUN ARCH=$(dpkg --print-architecture) && \
    mkdir -p /opt/mephi-cache && \
    if [ "$ARCH" = "arm64" ]; then BASE="http://ports.ubuntu.com/ubuntu-ports"; \
    else BASE="http://archive.ubuntu.com/ubuntu"; fi && \
    DEB_NAME=$(curl -sL "${BASE}/pool/main/t/tcpdump/" | \
        grep -oE "tcpdump_[0-9][^\"]*_${ARCH}\.deb" | sort -V | tail -1) && \
    echo "Качаем: ${BASE}/pool/main/t/tcpdump/${DEB_NAME}" && \
    wget -q -O "/opt/mephi-cache/${DEB_NAME}" "${BASE}/pool/main/t/tcpdump/${DEB_NAME}" && \
    ls -la /opt/mephi-cache

RUN systemctl mask \
        systemd-udevd.service \
        systemd-udevd-control.socket \
        systemd-udevd-kernel.socket \
        sys-kernel-debug.mount \
        sys-kernel-tracing.mount \
        dev-hugepages.mount \
        systemd-modules-load.service \
        systemd-networkd.service \
        NetworkManager-wait-online.service \
        2>/dev/null || true

RUN sed -i '/en_US.UTF-8/s/^# //; /ru_RU.UTF-8/s/^# //' /etc/locale.gen && \
    locale-gen

RUN mkdir -p /run/sshd && ssh-keygen -A && \
    systemctl enable ssh

# Скрипты инициализации и генерации отчёта
COPY init.sh             /usr/local/bin/mephi-init.sh
COPY generate_report.sh  /usr/local/bin/generate_report.sh
COPY mephi-init.service  /etc/systemd/system/mephi-init.service
# Текст rationale-блоков отчёта (отделён от верстки)
COPY content/            /opt/mephi-content/
RUN chmod +x /usr/local/bin/mephi-init.sh /usr/local/bin/generate_report.sh && \
    systemctl enable mephi-init.service

STOPSIGNAL SIGRTMIN+3

CMD ["/sbin/init"]
