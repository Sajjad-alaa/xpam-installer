# XPAM web: a plain nginx that serves only the admin console files. No ports are published; the gateway forwards
# /web/ to it. Stopping or replacing it does not affect the rest of XPAM.
#   docker build -f web.Dockerfile --build-context nginxconf=<this folder>/nginx -t xpam/web:<tag> /opt/xpam-web
# Stages: prep (clean) -> one clean layer (no upstream layers, history or labels) -> system updates -> our files.
FROM jumpserver/web@sha256:5971a1c6f088df1d3c785549d8566e224919abadc0006626259f961a3fd13ec2 AS prep
# Only nginx itself stays: no upstream application files, routes, start scripts or example certificate
RUN rm -rf /opt/lina /opt/luna /opt/download /docker-entrypoint.d/* /etc/nginx/conf.d/* /etc/nginx/includes \
        /etc/nginx/sites-enabled /etc/nginx/example \
    && mkdir -p /etc/nginx/stream.d

FROM scratch
COPY --from=prep / /
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WORKDIR /opt

# Security updates for the OS packages (same Debian release). A new build date re-runs the upgrade (otherwise the
# cached layer keeps old packages). (The upstream image points apt at a mirror only reachable inside Alibaba Cloud.)
ARG APT_REFRESH=0
RUN find /etc/apt -type f \( -name '*.sources' -o -name '*.list' \) -exec \
        sed -i -E 's#https?://mirrors\.(cloud\.)?aliyun(cs)?\.com#http://deb.debian.org#g' {} + \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends upgrade \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY lina /opt/web
# Compressed once at the strongest level (served by gzip_static): ~13% smaller downloads than nginx compressing
# each response at its default level, and no compression work per request
RUN find /opt/web -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.css' -o -name '*.svg' -o -name '*.json' \
        -o -name '*.html' -o -name '*.txt' -o -name '*.wasm' \) -size +1k -exec gzip -9 -k -f {} +
COPY --from=nginxconf web-static.conf /etc/nginx/conf.d/default.conf
RUN nginx -t
EXPOSE 8090
STOPSIGNAL SIGQUIT
HEALTHCHECK --interval=10s --timeout=5s --retries=3 CMD check http://localhost:8090/health
ENTRYPOINT ["nginx", "-g", "daemon off;"]
CMD []
