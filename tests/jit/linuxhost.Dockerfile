# The Linux target of the JIT tests (xpam-test/linuxhost): SSH with root login by password (ROOT_PASSWORD), Python
# for Ansible, sudo and the account tools. Built by access_run.sh when missing.
FROM debian:bookworm-slim
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openssh-server python3 sudo procps \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd \
    && sed -i -E 's/^#?PermitRootLogin .*/PermitRootLogin yes/; s/^#?PasswordAuthentication .*/PasswordAuthentication yes/' \
        /etc/ssh/sshd_config
EXPOSE 22
CMD ["sh", "-c", "echo \"root:${ROOT_PASSWORD:?set ROOT_PASSWORD}\" | chpasswd && exec /usr/sbin/sshd -D -e"]
