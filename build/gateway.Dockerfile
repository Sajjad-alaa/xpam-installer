# XPAM gateway: the front door (nginx: TLS, routing). It forwards /web/ and /workspace/ to their own containers, the
# service paths (/core/, /api/, /secureconnection/, /webconnector/, /ai/) to the services, and /ws/facelive/ to the
# face recognition engine when face recognition is on. Built on the upstream nginx image, with XPAM's own
# configuration and start scripts only.
#   docker build -f gateway.Dockerfile -t xpam/gateway:<tag> <this folder>/nginx
# Stages: prep (clean) -> one clean layer (no upstream layers, history or labels) -> system updates -> our files.
FROM jumpserver/web@sha256:5971a1c6f088df1d3c785549d8566e224919abadc0006626259f961a3fd13ec2 AS prep

# Nothing of the upstream application stays: its console files, routes, server template, start script, bundled
# version files and example certificate (a server without a certificate makes its own, see 40-xpam-init.sh).
RUN set -e; \
    rm -rf /opt/lina /opt/luna /opt/download /etc/nginx/includes /etc/nginx/sites-enabled /etc/nginx/example \
           /etc/nginx/conf.d/* /docker-entrypoint.d/40-init-config.sh; \
    mkdir -p /etc/nginx/includes /etc/nginx/sites-enabled /etc/nginx/stream.d /opt/download; \
    if grep -rIliE 'jumpserver|koko|chen|kael|lina|luna|jms' /etc/nginx /docker-entrypoint.d /opt 2>/dev/null | grep .; then \
      echo 'an upstream name is still in the files above'; exit 1; \
    fi

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

# The internal server (port 51980) that routes the requests, and the public HTTP/HTTPS servers in front of it
COPY default.conf /etc/nginx/conf.d/default.conf
COPY https_server.conf /etc/nginx/sites-enabled/https_server.conf
COPY common.conf core.conf interface_security.conf secureconnection.conf webconnector.conf ai.conf facelive.conf /etc/nginx/includes/
# Tell core which address and scheme the browser really used (host with port, http or https). Core then accepts
# sign-ins from whatever address reaches this server, without a hand-kept list of addresses (DOMAINS), while
# requests coming from other sites are still refused. A scheme header sent by the browser itself is overwritten.
COPY 00-xpam-proto.conf /etc/nginx/conf.d/00-xpam-proto.conf
# Start scripts (run by /docker-entrypoint.sh in name order): server names, HTTPS, certificate, switched-off services;
# the scheme behind a trusted load balancer; the face recognition route
COPY --chmod=755 40-xpam-init.sh 45-xpam-forwarded-proto.sh 47-xpam-facelive.sh /docker-entrypoint.d/
RUN nginx -t 2>&1 | tail -1
EXPOSE 80 443
STOPSIGNAL SIGQUIT
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
