# XPAM webconnector: official JumpServer v5.0.0 chen image + XPAM-built application jar
# (patched Spring Boot, Tomcat and Netty; served under /webconnector/) and a current PostgreSQL driver.
# Build the jar from /opt/xpam-webconnector first (see README in this folder), then:
#   docker build -f webconnector.Dockerfile --build-context jar=<dir containing chen.jar> \
#       -t xpam/webconnector:<tag> /opt/xpam-webconnector
FROM jumpserver/chen@sha256:c651c6a6666f00832a66a11ea38ec97cd49a8cf92532cfdb6418463212d3aa59
# Security updates for the OS packages inherited from the upstream image (same Debian release)
# (the upstream image points apt at a mirror that is only reachable inside Alibaba Cloud)
RUN find /etc/apt -type f \( -name '*.sources' -o -name '*.list' \) -exec \
        sed -i -E 's#https?://mirrors\.(cloud\.)?aliyun(cs)?\.com#http://deb.debian.org#g' {} + \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends upgrade \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
COPY --from=jar chen.jar /opt/chen/chen.jar
RUN rm -f /opt/chen/drivers/postgresql/postgresql-*.jar
COPY drivers/postgresql/ /opt/chen/drivers/postgresql/
# Entrypoint that masks the registration token in the container log
COPY --chmod=755 entrypoint.sh /opt/chen/entrypoint.sh
COPY config/application.yml /tmp/xpam-application.yml
RUN grep -q '^    context-path: /webconnector$' /tmp/xpam-application.yml \
    && sed -i 's#^    context-path: /chen$#    context-path: /webconnector#' /opt/chen/config/application.yml \
    && grep -q '^    context-path: /webconnector$' /opt/chen/config/application.yml \
    && rm /tmp/xpam-application.yml
HEALTHCHECK --interval=10s --timeout=5s --retries=3 CMD check http://localhost:8082/webconnector/healthy
