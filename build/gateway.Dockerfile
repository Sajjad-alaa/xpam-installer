# XPAM gateway: the front door. Official JumpServer v5.0.0 web image (nginx, TLS, routing) without any
# application files. It forwards /web/ and /workspace/ to their own containers and the service paths
# (/core/, /api/, /secureconnection/, /webconnector/, /ai/) to the services.
#   docker build -f gateway.Dockerfile -t xpam/gateway:<tag> <this folder>/nginx
# Official JumpServer v5.0.0-ce image, pinned by digest (same image on every build host)
FROM jumpserver/web@sha256:5971a1c6f088df1d3c785549d8566e224919abadc0006626259f961a3fd13ec2
# Security updates for the OS packages inherited from the upstream image (same Debian release)
# (the upstream image points apt at a mirror that is only reachable inside Alibaba Cloud)
RUN find /etc/apt -type f \( -name '*.sources' -o -name '*.list' \) -exec \
        sed -i -E 's#https?://mirrors\.(cloud\.)?aliyun(cs)?\.com#http://deb.debian.org#g' {} + \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends upgrade \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
RUN rm -rf /opt/lina /opt/luna
COPY default.conf /etc/nginx/conf.d/default.conf
# Component routes under their XPAM names; the init script enables/disables them by these names
RUN rm -f /etc/nginx/includes/koko.conf* /etc/nginx/includes/chen.conf* /etc/nginx/includes/kael.conf* \
    && sed -i 's#includes/koko\.conf#includes/secureconnection.conf#g; s#includes/chen\.conf#includes/webconnector.conf#g; s#includes/kael\.conf#includes/ai.conf#g' \
        /docker-entrypoint.d/40-init-config.sh \
    && ! grep -qE 'includes/(koko|chen|kael)\.conf' /docker-entrypoint.d/40-init-config.sh
COPY common.conf core.conf interface_security.conf secureconnection.conf webconnector.conf ai.conf /etc/nginx/includes/
# HTTPS only from now on for this host name: browsers stop trying plain HTTP for a year
RUN sed -i 's#^  server_tokens off;#  server_tokens off;\n  add_header Strict-Transport-Security "max-age=31536000" always;#' /etc/nginx/sites-enabled/https_server.conf \
    && grep -q 'Strict-Transport-Security' /etc/nginx/sites-enabled/https_server.conf
