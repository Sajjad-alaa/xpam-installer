# XPAM ai: official JumpServer v5.0.0 kael image + XPAM-built binary (public path /ai/).
# Build the binary from /opt/xpam-ai first (see README in this folder), then:
#   docker build -f ai.Dockerfile -t xpam/ai:<tag> <dir containing the kael binary>
# Official JumpServer v5.0.0-ce image, pinned by digest (same image on every build host)
FROM jumpserver/kael@sha256:683a00265ad23cbc9ebf38a0a8e3e53717489f62f41644ba65e9da2750c5c420
# Security updates for the OS packages inherited from the upstream image (same Debian release)
# (the upstream image points apt at a mirror that is only reachable inside Alibaba Cloud)
RUN find /etc/apt -type f \( -name '*.sources' -o -name '*.list' \) -exec \
        sed -i -E 's#https?://mirrors\.(cloud\.)?aliyun(cs)?\.com#http://deb.debian.org#g' {} + \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends upgrade \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
# The assistant only needs the node runtime; the package managers are not used at run time
# and carry their own vulnerable dependencies
RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack /opt/yarn-v* \
        /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack /usr/local/bin/yarn /usr/local/bin/yarnpkg \
    && node --version && codex --version
COPY kael /opt/kael/kael
HEALTHCHECK --interval=10s --timeout=5s --retries=3 CMD check http://localhost:8083/ai/health/ready
