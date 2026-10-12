# XPAM web: official JumpServer v5.0.0 web image + XPAM web (admin UI) and workspace (web terminal).
# Public paths: /web/, /workspace/, /secureconnection/, /webconnector/, /ai/ (old /ui/ and /luna/ answer with
# 301 redirects; /koko/, /chen/ and /kael/ stay as hidden proxy aliases, see nginx/).
# Build (BuildKit), with the workspace static output and nginx confs as named contexts:
#   docker build -f web.Dockerfile --build-context workspace=/opt/xpam-workspace/.output/public \
#                --build-context nginxconf=/opt/xpam-build/nginx -t xpam/web:<tag> /opt/xpam-web
# Official JumpServer v5.0.0-ce image, pinned by digest (same image on every build host)
FROM jumpserver/web@sha256:5971a1c6f088df1d3c785549d8566e224919abadc0006626259f961a3fd13ec2
RUN rm -rf /opt/lina /opt/luna /opt/web /opt/workspace
COPY lina /opt/web
COPY --from=workspace . /opt/workspace
COPY --from=nginxconf default.conf /etc/nginx/conf.d/default.conf
# Component routes under their XPAM names; the init script enables/disables them by these names
RUN rm -f /etc/nginx/includes/koko.conf* /etc/nginx/includes/chen.conf* /etc/nginx/includes/kael.conf* \
    && sed -i 's#includes/koko\.conf#includes/secureconnection.conf#g; s#includes/chen\.conf#includes/webconnector.conf#g; s#includes/kael\.conf#includes/ai.conf#g' \
        /docker-entrypoint.d/40-init-config.sh \
    && ! grep -qE 'includes/(koko|chen|kael)\.conf' /docker-entrypoint.d/40-init-config.sh
COPY --from=nginxconf common.conf interface_security.conf secureconnection.conf webconnector.conf ai.conf /etc/nginx/includes/
