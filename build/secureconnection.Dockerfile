# XPAM secureconnection: official JumpServer v5.0.0 koko image + XPAM-built binary
# (native RDP RemoteApp, public path /secureconnection/, remote desktop under /secureconnection/desktop/).
# Build the binary from /opt/xpam-secureconnection first (see README in this folder), then:
#   docker build -f secureconnection.Dockerfile -t xpam/secureconnection:<tag> <dir containing the koko binary>
# Official JumpServer v5.0.0-ce image, pinned by digest (same image on every build host)
FROM jumpserver/koko@sha256:6884e2b8bc6b9da9d991ebf045691277bb9bceec4ef10699aa12492adde3aa16
# Security updates for the OS packages inherited from the upstream image (same Debian release)
# (the upstream image points apt at a mirror that is only reachable inside Alibaba Cloud)
RUN find /etc/apt -type f \( -name '*.sources' -o -name '*.list' \) -exec \
        sed -i -E 's#https?://mirrors\.(cloud\.)?aliyun(cs)?\.com#http://deb.debian.org#g' {} + \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends upgrade \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
COPY koko /opt/koko/koko
# Database command-line client rebuilt from the same source release with a current Go toolchain
# and current golang.org/x libraries (see build-all.sh)
COPY --chmod=755 usql /usr/local/bin/usql
RUN usql --version
HEALTHCHECK --interval=10s --timeout=5s --retries=3 CMD check http://localhost:5000/secureconnection/health/
