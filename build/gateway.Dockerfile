# XPAM gateway: the front door. Official JumpServer v5.0.0 web image (nginx, TLS, routing) without any
# application files. It forwards /web/ and /workspace/ to their own containers and the service paths
# (/core/, /api/, /secureconnection/, /webconnector/, /ai/) to the services.
#   docker build -f gateway.Dockerfile -t xpam/gateway:<tag> <this folder>/nginx
# Official JumpServer v5.0.0-ce image, pinned by digest (same image on every build host)
FROM jumpserver/web@sha256:5971a1c6f088df1d3c785549d8566e224919abadc0006626259f961a3fd13ec2
RUN rm -rf /opt/lina /opt/luna
COPY default.conf /etc/nginx/conf.d/default.conf
# Component routes under their XPAM names; the init script enables/disables them by these names
RUN rm -f /etc/nginx/includes/koko.conf* /etc/nginx/includes/chen.conf* /etc/nginx/includes/kael.conf* \
    && sed -i 's#includes/koko\.conf#includes/secureconnection.conf#g; s#includes/chen\.conf#includes/webconnector.conf#g; s#includes/kael\.conf#includes/ai.conf#g' \
        /docker-entrypoint.d/40-init-config.sh \
    && ! grep -qE 'includes/(koko|chen|kael)\.conf' /docker-entrypoint.d/40-init-config.sh
COPY common.conf core.conf interface_security.conf secureconnection.conf webconnector.conf ai.conf /etc/nginx/includes/
