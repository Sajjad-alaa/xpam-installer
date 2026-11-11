# XPAM webconnector: the database web console. Built on the upstream image (its Java runtime, launcher and database
# drivers), with XPAM's own application jar, names and paths.
# Build:  docker build -f webconnector.Dockerfile --build-context jar=<folder with webconnector.jar> \
#           -t xpam/webconnector:<tag> /opt/xpam-webconnector
# Stages: prep (rename, clean) -> one clean layer (no upstream layers, history or labels) -> system updates -> our files.
FROM jumpserver/chen@sha256:c651c6a6666f00832a66a11ea38ec97cd49a8cf92532cfdb6418463212d3aa59 AS prep

# The installation folder is /opt/webconnector. The upstream jar, entry point and configuration go (ours are added
# below), and the PostgreSQL driver is replaced by the repository's patched one. The clock defaults to UTC (TZ in
# config.txt overrides it).
RUN set -e; \
    mv /opt/chen /opt/webconnector; \
    rm -f /opt/webconnector/chen.jar /opt/webconnector/entrypoint.sh /opt/webconnector/config/application.yml \
          /opt/webconnector/drivers/postgresql/postgresql-*.jar; \
    ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime; echo 'Etc/UTC' > /etc/timezone; \
    if grep -rIliE 'chen|jumpserver|jms_' /opt/webconnector --exclude-dir=drivers 2>/dev/null | grep .; then \
      echo 'an old name is still in the files above'; exit 1; \
    fi

FROM scratch
COPY --from=prep / /
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WORKDIR /opt/webconnector

# Security updates for the OS packages inherited from the upstream image (same Debian release)
# (the upstream image points apt at a mirror that is only reachable inside Alibaba Cloud)
# a new build date re-runs the system upgrade (otherwise the cached layer keeps old packages)
ARG APT_REFRESH=0
RUN find /etc/apt -type f \( -name '*.sources' -o -name '*.list' \) -exec \
        sed -i -E 's#https?://mirrors\.(cloud\.)?aliyun(cs)?\.com#http://deb.debian.org#g' {} + \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Application jar rebuilt from xpam-webconnector with patched Spring Boot, Tomcat, Netty and Jackson (build-all.sh)
COPY --from=jar webconnector.jar /opt/webconnector/webconnector.jar
# Current PostgreSQL JDBC driver
COPY drivers/postgresql/ /opt/webconnector/drivers/postgresql/
COPY --chmod=755 entrypoint.sh /opt/webconnector/entrypoint.sh
# Its settings: public path /webconnector/, log file, message bundle
COPY config/application.yml /opt/webconnector/config/application.yml
RUN grep -q '^    context-path: /webconnector$' /opt/webconnector/config/application.yml \
    && mkdir -p /opt/webconnector/data
EXPOSE 8082
STOPSIGNAL SIGQUIT
ENTRYPOINT ["./entrypoint.sh"]
CMD ["wisp"]
HEALTHCHECK --interval=10s --timeout=5s --retries=3 CMD check http://localhost:8082/webconnector/healthy
