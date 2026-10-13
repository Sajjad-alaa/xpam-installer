# XPAM workspace: a plain nginx that serves only the workspace (web terminal) files. No ports are published; the
# gateway forwards /workspace/ to it. Stopping or replacing it does not affect the rest of XPAM.
#   docker build -f workspace.Dockerfile --build-context nginxconf=<this folder>/nginx -t xpam/workspace:<tag> /opt/xpam-workspace/.output/public
# Official JumpServer v5.0.0-ce web image (nginx), pinned by digest (same image on every build host)
FROM jumpserver/web@sha256:5971a1c6f088df1d3c785549d8566e224919abadc0006626259f961a3fd13ec2
# Security updates for the OS packages inherited from the upstream image (same Debian release)
# (the upstream image points apt at a mirror that is only reachable inside Alibaba Cloud)
RUN find /etc/apt -type f \( -name '*.sources' -o -name '*.list' \) -exec \
        sed -i -E 's#https?://mirrors\.(cloud\.)?aliyun(cs)?\.com#http://deb.debian.org#g' {} + \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends upgrade \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
# Drop the gateway's configuration, startup scripts and bundled files: this container only serves files
RUN rm -rf /opt/lina /opt/luna /opt/download /docker-entrypoint.d/* /etc/nginx/conf.d/* /etc/nginx/includes \
        /etc/nginx/sites-enabled /etc/nginx/stream.d/*
COPY . /opt/workspace
COPY --from=nginxconf workspace-static.conf /etc/nginx/conf.d/default.conf
RUN nginx -t
EXPOSE 8090
HEALTHCHECK --interval=10s --timeout=5s --retries=3 CMD check http://localhost:8090/health
ENTRYPOINT ["nginx", "-g", "daemon off;"]
CMD []
