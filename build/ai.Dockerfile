# XPAM ai: the AI assistant service. Built on the upstream image (its Node runtime and the coding agent it drives),
# with XPAM's own binary, names and paths.
# Build:  docker build -f ai.Dockerfile -t xpam/ai:<tag> <folder with the built "ai" binary and "entrypoint.sh">
# Stages: prep (rename, clean) -> one clean layer (no upstream layers, history or labels) -> system updates -> our files.
FROM jumpserver/kael@sha256:683a00265ad23cbc9ebf38a0a8e3e53717489f62f41644ba65e9da2750c5c420 AS prep

# The installation folder is /opt/ai; the upstream binary, entry point and example configuration go. The agent
# does not need a package manager at run time: npm, npx, corepack and yarn are removed.
RUN set -e; \
    mv /opt/kael /opt/ai; \
    rm -f /opt/ai/kael /opt/ai/entrypoint.sh /opt/ai/config_example.yml; \
    rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack /opt/yarn-v* \
        /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack /usr/local/bin/yarn /usr/local/bin/yarnpkg; \
    node --version && codex --version; \
    if grep -rIliE 'kael|jumpserver|jms_' /opt/ai /etc/profile.d /root 2>/dev/null | grep .; then \
      echo 'an old name is still in the files above'; exit 1; \
    fi

FROM scratch
COPY --from=prep / /
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    NODE_VERSION=22.23.3
WORKDIR /opt/ai

# Security updates for the OS packages inherited from the upstream image (same Debian release)
# (the upstream image points apt at a mirror that is only reachable inside Alibaba Cloud)
# a new build date re-runs the system upgrade (otherwise the cached layer keeps old packages)
ARG APT_REFRESH=0
RUN find /etc/apt -type f \( -name '*.sources' -o -name '*.list' \) -exec \
        sed -i -E 's#https?://mirrors\.(cloud\.)?aliyun(cs)?\.com#http://deb.debian.org#g' {} + \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends upgrade \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# The service binary, built from xpam-ai (build-all.sh), and its entry point
COPY --chmod=755 ai /opt/ai/ai
COPY --chmod=755 entrypoint.sh /opt/ai/entrypoint.sh
RUN mkdir -p /opt/ai/data
EXPOSE 8083
ENTRYPOINT ["./entrypoint.sh"]
HEALTHCHECK --interval=10s --timeout=5s --retries=3 CMD check http://localhost:8083/ai/health/ready
