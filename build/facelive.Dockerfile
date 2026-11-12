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
# Build the package under a short, neutral directory (/b) so the only path Cython bakes into the
# modules (the C file name, seen in a traceback) is "/b/facelive/<module>.c" — no product or install
# path. The runtime copies the compiled package to /opt/facelive/facelive below; module names stay
# facelive.* either way (the package directory is named facelive).
WORKDIR /b
COPY facelive ./facelive
COPY tools ./tools
# Compile the engine's Python to native modules (.so) so the image ships no readable source, with
# HARDEN_MAX so each .so gives up as little as possible to inspection (no debug info, no compiler
# fingerprint, no embedded Python snippets, only PyInit_<module> exported; see compile_py.sh). This
# runs in the (discarded) build stage, so the toolchain never reaches the runtime image. __main__.py
# is a thin launcher and __init__.py only the version string; all logic is in compiled modules.
# --build-arg XPAM_COMPILE=0 skips compilation (readable source, for debugging a build).
ARG XPAM_COMPILE=1
COPY --from=xpamscripts compile_py.sh /tmp/compile_py.sh
COPY --from=xpamscripts strip_docstrings.py /tmp/strip_docstrings.py
RUN if [ "$XPAM_COMPILE" = "1" ]; then set -e; \
      apt-get update >/dev/null \
      && apt-get -y --no-install-recommends install gcc binutils libc6-dev >/dev/null; \
      /opt/venv/bin/pip install -q --retries 10 --timeout 180 Cython setuptools; \
      JOBS="$(nproc)" PYBIN=/opt/venv/bin/python ROOT_IS_PACKAGE=1 HARDEN_MAX=1 sh /tmp/compile_py.sh /b/facelive; \
      /opt/venv/bin/pip uninstall -y -q Cython >/dev/null 2>&1 || true; \
    fi; rm -f /tmp/compile_py.sh /tmp/strip_docstrings.py
RUN /opt/venv/bin/python -B tools/fetch_models.py /b/models

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
COPY --from=build /b/facelive /opt/facelive/facelive
COPY --from=build /b/models /opt/facelive/models
COPY --chmod=755 entrypoint.sh /opt/facelive/entrypoint.sh
COPY NOTICE /opt/facelive/NOTICE
ENV PATH=/opt/venv/bin:$PATH PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 \
    FACELIVE_MODEL_DIR=/opt/facelive/models FACELIVE_PORT=8085 OMP_NUM_THREADS=2 \
    OPENCV_IO_MAX_IMAGE_WIDTH=1920 OPENCV_IO_MAX_IMAGE_HEIGHT=1920 OPENCV_IO_MAX_IMAGE_PIXELS=3686400
WORKDIR /opt/facelive
# the packaging tools are not used at run time (setuptools carries copies of wheel and jaraco.context with known
# flaws): removed from the application's environment and from the base Python
RUN /opt/venv/bin/python -m pip uninstall -y -q setuptools wheel >/dev/null 2>&1; \
    /opt/venv/bin/python -m pip uninstall -y -q pip >/dev/null 2>&1; \
    python -m pip uninstall -y -q setuptools wheel >/dev/null 2>&1; \
    python -m pip uninstall -y -q pip >/dev/null 2>&1; \
    rm -rf /opt/venv/lib/python3.11/site-packages/setuptools* /usr/local/lib/python3.11/site-packages/setuptools*; \
    ! ls -d /opt/venv/lib/python3.11/site-packages/setuptools /usr/local/lib/python3.11/site-packages/setuptools 2>/dev/null
# fail the build if OpenCV or the models do not load, then drop the bytecode cache the check writes
# (only __init__.pyc, the version string) so the image ships no .pyc at all
RUN python -B -m facelive --check \
    && find /opt/facelive -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null; true
USER 10001:10001
EXPOSE 8085
HEALTHCHECK --interval=10s --timeout=5s --retries=3 --start-period=60s \
    CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8085/facelive/health', timeout=4)"]
ENTRYPOINT ["/opt/facelive/entrypoint.sh"]
