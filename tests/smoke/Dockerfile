ARG BASE=ubuntu:24.04
FROM ${BASE}
ENV container=docker DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
RUN apt-get update \
 && apt-get install -y --no-install-recommends systemd systemd-sysv dbus init openssh-server procps \
 && apt-get install -y --no-install-recommends systemd systemd-sysv dbus init openssh-server procps ufw \
 && apt-get clean && rm -rf /var/lib/apt/lists/* /etc/ssh/sshd_config.d/60-cloudimg-settings.conf
RUN systemctl enable ssh 2>/dev/null || true
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
