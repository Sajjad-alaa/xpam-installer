# XPAM browser service: web assets shown in any browser without their address (one isolated
# Chromium per session in kiosk mode, streamed through Lion over VNC).
# Build:  docker build -f browser.Dockerfile -t xpam/browser:<tag> /opt/xpam-secureconnection/browser
FROM debian:bookworm-slim

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       chromium xvfb x11vnc python3 tini ca-certificates fonts-dejavu-core fonts-liberation fonts-noto-core \
    && apt-get -y --no-install-recommends upgrade \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && useradd -m -u 1000 -s /usr/sbin/nologin browser \
    && mkdir -p /tmp/.X11-unix /etc/chromium/policies/managed \
    && chmod 1777 /tmp/.X11-unix

COPY policies.json /etc/chromium/policies/managed/xpam.json
COPY server.py /opt/xpam-browser/server.py

USER browser
EXPOSE 9001
HEALTHCHECK --interval=15s --timeout=5s --retries=5 \
  CMD python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:9001/health', timeout=4)"
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["python3", "/opt/xpam-browser/server.py"]
