# XPAM webconnector: official JumpServer v5.0.0 chen image served under /webconnector/
# (Spring context path; the config lives in /opt/xpam-webconnector/config/application.yml).
#   docker build -f webconnector.Dockerfile -t xpam/webconnector:<tag> /opt/xpam-webconnector/config
# Official JumpServer v5.0.0-ce image, pinned by digest (same image on every build host)
FROM jumpserver/chen@sha256:c651c6a6666f00832a66a11ea38ec97cd49a8cf92532cfdb6418463212d3aa59
# Security updates for the OS packages inherited from the upstream image (same Debian release)
# (the upstream image points apt at a mirror that is only reachable inside Alibaba Cloud)
RUN find /etc/apt -type f \( -name '*.sources' -o -name '*.list' \) -exec \
        sed -i -E 's#https?://mirrors\.(cloud\.)?aliyun(cs)?\.com#http://deb.debian.org#g' {} + \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends upgrade \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
COPY application.yml /tmp/xpam-application.yml
RUN grep -q '^    context-path: /webconnector$' /tmp/xpam-application.yml \
    && sed -i 's#^    context-path: /chen$#    context-path: /webconnector#' /opt/chen/config/application.yml \
    && grep -q '^    context-path: /webconnector$' /opt/chen/config/application.yml \
    && rm /tmp/xpam-application.yml
HEALTHCHECK --interval=10s --timeout=5s --retries=3 CMD check http://localhost:8082/webconnector/healthy
