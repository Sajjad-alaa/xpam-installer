# XPAM secureconnection: terminal, desktop (RDP/VNC) and SSH connections to assets. Built on the upstream connection
# image (its Guacamole build, database and Kubernetes clients), with XPAM's own binary, names and paths.
# Build:  docker build -f secureconnection.Dockerfile --build-context xpamscripts=<this folder> \
#           -t xpam/secureconnection:<tag> <folder with the built "secureconnection" binary and "usql">
# Stages: prep (rename, clean) -> one clean layer (no upstream layers, history or labels) -> system updates -> our files.
FROM jumpserver/koko@sha256:6884e2b8bc6b9da9d991ebf045691277bb9bceec4ef10699aa12492adde3aa16 AS prep

# The installation folder is /opt/secureconnection and the service is named after it. The upstream binary, start
# scripts and other languages go (XPAM is English only; the English messages keep their file, renamed); unused
# Guacamole development files and docs go too (the bundled libraries' licence files stay: libssh2's BSD licence must
# ship with the binaries). The Kubernetes session helper names its Linux user and kubectl credential after XPAM.
# The clock defaults to UTC (TZ in config.txt overrides it). The step fails if an old name is left in a script.
RUN set -e; \
    mv /opt/koko /opt/secureconnection; \
    mv /etc/services.d/koko /etc/services.d/secureconnection; \
    rm -f /etc/cont-init.d/10-koko-init /etc/services.d/secureconnection/run /opt/secureconnection/entrypoint.sh \
          /opt/secureconnection/koko /opt/secureconnection/config_example.yml; \
    find /opt/secureconnection/locale -mindepth 1 -maxdepth 1 -type d ! -name en -exec rm -rf {} +; \
    mv /opt/secureconnection/locale/en/LC_MESSAGES/koko.mo /opt/secureconnection/locale/en/LC_MESSAGES/secureconnection.mo; \
    rm -f /opt/secureconnection/locale/en/LC_MESSAGES/koko.po; \
    sed -i 's#/opt/koko#/opt/secureconnection#g' /etc/services.d/guacd/log/run; \
    sed -i 's/init_jms_k8s_user/init_k8s_user/g; s/jms_k8s_user/xpam_k8s_user/g; s/JumpServer-user/xpam-user/g' \
        /opt/secureconnection/init-kubectl.sh; \
    rm -rf /opt/guacamole/include /opt/guacamole/lib/cmake /opt/guacamole/lib/pkgconfig /opt/guacamole/lib/*.a \
           /opt/guacamole/lib/*.la /opt/guacamole/share/man /opt/guacamole/DEPENDENCIES; \
    find /opt/guacamole/share/doc -type f ! -iname 'COPYING*' ! -iname 'LICENSE*' ! -iname 'NOTICE*' -delete; \
    find /opt/guacamole/share/doc -depth -type d -empty -delete; \
    ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime; echo 'Etc/UTC' > /etc/timezone; \
    ls /opt/secureconnection/locale/en/LC_MESSAGES/secureconnection.mo; \
    if grep -rIliE 'koko|jumpserver|jms_' /etc/cont-init.d /etc/services.d /opt/secureconnection 2>/dev/null | grep .; then \
      echo 'an old name is still in the files above'; exit 1; \
    fi

FROM scratch
COPY --from=prep / /
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    LC_ALL=C.UTF-8 LANG=C.UTF-8 \
    LD_LIBRARY_PATH=/opt/guacamole/lib \
    GUACD_LOG_LEVEL=info
WORKDIR /opt/secureconnection

# Security updates for the OS packages inherited from the upstream image (same Debian release)
# (the upstream image points apt at a mirror that is only reachable inside Alibaba Cloud)
# a new build date re-runs the system upgrade (otherwise the cached layer keeps old packages)
ARG APT_REFRESH=0
RUN find /etc/apt -type f \( -name '*.sources' -o -name '*.list' \) -exec \
        sed -i -E 's#https?://mirrors\.(cloud\.)?aliyun(cs)?\.com#http://deb.debian.org#g' {} + \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends upgrade \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# The service binary, built from xpam-secureconnection (build-all.sh), and its start scripts (s6: /init runs
# cont-init.d once, then supervises services.d)
COPY --chmod=755 secureconnection /opt/secureconnection/secureconnection
COPY --from=xpamscripts --chmod=755 secureconnection/10-init /etc/cont-init.d/10-init
COPY --from=xpamscripts --chmod=755 secureconnection/run /etc/services.d/secureconnection/run
# Database command-line client rebuilt from the same source release with a current Go toolchain
# and current golang.org/x libraries (see build-all.sh)
COPY --chmod=755 usql /usr/local/bin/usql
ARG XPAM_VERSION=dev
ENV XPAM_VERSION=${XPAM_VERSION}
RUN usql --version && /opt/secureconnection/secureconnection --version 2>/dev/null | head -1 || true
EXPOSE 2222 4822 5000 5001
STOPSIGNAL SIGQUIT
ENTRYPOINT ["/init"]
HEALTHCHECK --interval=10s --timeout=5s --retries=3 CMD check http://localhost:5000/secureconnection/health/
