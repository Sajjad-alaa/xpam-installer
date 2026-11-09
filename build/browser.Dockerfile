# XPAM browser service: web assets shown in any browser without their address (one isolated
# Chromium per session in kiosk mode, streamed through Lion over VNC).
# Build:  docker build -f browser.Dockerfile -t xpam/browser:<tag> /opt/xpam-secureconnection/browser

# --- build stage: compile the service to a native module so the image ships no readable source.
# Same Debian/Python as the runtime (bookworm -> python3.11) so the .so matches its ABI. Toolchain
# stays in this discarded stage. --build-arg XPAM_COMPILE=0 ships server.py as source instead.
FROM debian:bookworm-slim AS build
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       python3 python3-dev gcc binutils python3-pip python3-setuptools \
    && pip3 install --no-cache-dir --break-system-packages --retries 10 --timeout 180 Cython \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/xpam-browser
COPY server.py .
COPY --from=xpamscripts strip_docstrings.py /tmp/strip_docstrings.py
ARG XPAM_COMPILE=1
RUN if [ "$XPAM_COMPILE" = "1" ]; then set -e; \
      export CFLAGS="-O2 -g0 -fvisibility=hidden -ffunction-sections -fdata-sections -fstack-protector-strong -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=2 -fPIC"; \
      export LDFLAGS="-g0 -Wl,--build-id=none -Wl,--gc-sections -Wl,-s -Wl,-z,relro,-z,now"; \
      python3 /tmp/strip_docstrings.py --unsafe-list /tmp/unsafe server.py; \
      if [ -s /tmp/unsafe ]; then \
        echo "server.py: a zero-argument super() inside a comprehension fails once compiled; write super(Class, self)"; \
        exit 1; \
      fi; \
      python3 -m Cython.Build.Cythonize -i -3 -X annotation_typing=False -X emit_code_comments=False server.py; \
      ls server.*.so >/dev/null; \
      strip --strip-all --remove-section=.comment --remove-section=.note.gnu.build-id --remove-section=.note.gnu.property server.*.so; \
      rm -f server.py server.c; \
    fi; rm -f /tmp/strip_docstrings.py

# --- runtime stage
FROM debian:bookworm-slim

# a new build date re-runs the system upgrade (otherwise the cached layer keeps old packages)
ARG APT_REFRESH=0
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       chromium xvfb x11vnc python3 tini ca-certificates fonts-dejavu-core fonts-liberation fonts-noto-core \
    && apt-get -y --no-install-recommends upgrade \
    && apt-get clean && rm -rf /var/lib/apt/lists/* \
    && useradd -m -u 1000 -s /usr/sbin/nologin browser \
    && mkdir -p /tmp/.X11-unix /etc/chromium/policies/managed \
    && chmod 1777 /tmp/.X11-unix

COPY policies.json /etc/chromium/policies/managed/xpam.json
# the compiled service module (server*.so) or, with XPAM_COMPILE=0, server.py
COPY --from=build /opt/xpam-browser/server.* /opt/xpam-browser/
# thin readable launcher that imports and starts it
COPY run.py /opt/xpam-browser/run.py

USER browser
EXPOSE 9001
HEALTHCHECK --interval=15s --timeout=5s --retries=5 \
  CMD python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:9001/health', timeout=4)"
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["python3", "/opt/xpam-browser/run.py"]
