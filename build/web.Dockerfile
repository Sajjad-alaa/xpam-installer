# XPAM web: a plain nginx that serves only the admin console files. No ports are published; the
# gateway forwards /web/ to it. Stopping or replacing it does not affect the rest of XPAM.
#   docker build -f web.Dockerfile --build-context nginxconf=<this folder>/nginx -t xpam/web:<tag> /opt/xpam-web
# Official JumpServer v5.0.0-ce web image (nginx), pinned by digest (same image on every build host)
FROM jumpserver/web@sha256:5971a1c6f088df1d3c785549d8566e224919abadc0006626259f961a3fd13ec2
# Drop the gateway's configuration, startup scripts and bundled files: this container only serves files
RUN rm -rf /opt/lina /opt/luna /opt/download /docker-entrypoint.d/* /etc/nginx/conf.d/* /etc/nginx/includes \
        /etc/nginx/sites-enabled /etc/nginx/stream.d/*
COPY lina /opt/web
COPY --from=nginxconf web-static.conf /etc/nginx/conf.d/default.conf
RUN nginx -t
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=5s --retries=3 CMD check http://localhost:8080/health
ENTRYPOINT ["nginx", "-g", "daemon off;"]
CMD []
