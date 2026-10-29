# XPAM facelive: face recognition engine for face enrolment and face sign-in (public path /ws/facelive/).
# Built from /opt/xpam-facelive (OpenCV YuNet + SFace, both commercially usable; see its NOTICE):
#   docker build -f facelive.Dockerfile -t xpam/facelive:<tag> /opt/xpam-facelive
# The two model files are downloaded here, at build time, and checked against pinned SHA-256 values; the
# service checks them again at every start. Runs as a non-root user and works with a read-only root file system.

# --- build stage: Python packages and models
# Official Python 3.11 (Debian 12), pinned by digest (same image on every build host)
FROM python:3.11-slim-bookworm@sha256:94a8fee35252d06ab75856f15f12c7bae67b10e8a6da93c7fded82b2610926cd AS build
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_CACHE_DIR=1
RUN python -m venv /opt/venv
COPY requirements.txt /tmp/requirements.txt
RUN /opt/venv/bin/pip install --no-compile -r /tmp/requirements.txt
WORKDIR /opt/facelive
COPY facelive ./facelive
COPY tools ./tools
RUN /opt/venv/bin/python tools/fetch_models.py /opt/facelive/models

# --- runtime stage
FROM python:3.11-slim-bookworm@sha256:94a8fee35252d06ab75856f15f12c7bae67b10e8a6da93c7fded82b2610926cd
# Security updates for the OS packages (a new build date re-runs the system upgrade)
ARG APT_REFRESH=0
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends upgrade \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
# fixed numeric user: the installer gives the data folder to uid 10001
RUN groupadd --gid 10001 facelive \
    && useradd --uid 10001 --gid 10001 --no-create-home --home-dir /opt/facelive --shell /usr/sbin/nologin facelive \
    && mkdir -p /opt/facelive/data/keys && chown -R 10001:10001 /opt/facelive/data && chmod 700 /opt/facelive/data/keys
COPY --from=build /opt/venv /opt/venv
COPY --from=build /opt/facelive/facelive /opt/facelive/facelive
COPY --from=build /opt/facelive/models /opt/facelive/models
COPY --chmod=755 entrypoint.sh /opt/facelive/entrypoint.sh
COPY NOTICE /opt/facelive/NOTICE
ENV PATH=/opt/venv/bin:$PATH PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 \
    FACELIVE_MODEL_DIR=/opt/facelive/models FACELIVE_PORT=8085 OMP_NUM_THREADS=2
WORKDIR /opt/facelive
# fail the build if OpenCV or the models do not load
RUN python -m facelive --check
USER 10001:10001
EXPOSE 8085
HEALTHCHECK --interval=10s --timeout=5s --retries=3 --start-period=60s \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8085/facelive/health', timeout=4)"]
ENTRYPOINT ["/opt/facelive/entrypoint.sh"]
