# XPAM core: official JumpServer v5.0.0 release image + XPAM code overlay.
# Build:  docker build -f core.Dockerfile -t xpam/core:<tag> /opt/xpam-core
# Official JumpServer v5.0.0-ce image, pinned by digest (same image on every build host)
FROM jumpserver/core@sha256:902c58566c5248f3752309c8fb34c2f61b1ba39bde54a7439b36115afb7fd16d AS base

# Security upgrades for critical Python dependencies (FIX-08)
RUN /usr/local/bin/uv pip install --python /opt/py3/bin/python \
    "Django==5.2.17" "PyJWT==2.15.0" "urllib3==2.8.0" "requests==2.33.0" \
    "tornado==6.5.9" "pypdf==6.19.0" "werkzeug==3.1.3" "pymongo==4.18.2" \
    "cryptography==50.0.2" "pyOpenSSL==26.4.0" "mistune==3.3.4" \
    "ansible-core==2.16.19" "aiohttp==3.14.4"

# Oracle driver (thin mode, no Oracle client needed): Oracle secret automations and
# just-in-time database accounts (upstream ships it only with the enterprise build)
RUN /usr/local/bin/uv pip install --python /opt/py3/bin/python "oracledb==3.4.2"

# Network device accounts (FortiGate, Palo Alto, Cisco, Juniper, Huawei, H3C): push, change secret,
# removal, discovery and just-in-time accounts (libs/ansible/modules_utils/network_device.py)
RUN /usr/local/bin/uv pip install --python /opt/py3/bin/python "netmiko==4.5.0"

# Reports > Export PDF / Send by e-mail (apps/reports/views.py): Playwright renders the report page in
# its headless Chromium; pdf2image turns the PDF into images for the e-mail (poppler's pdftoppm).
# Only the libraries the headless shell links are installed (playwright's --with-deps would add a
# desktop/X stack) plus fonts for Latin, Arabic and CJK text. About 700 MB, mostly Chromium, the
# Playwright driver and the Mesa/LLVM stack Debian's libgbm1 requires. --build-arg XPAM_REPORT_PDF=0
# leaves it out (report export then answers with an error, nothing else changes).
ARG XPAM_REPORT_PDF=1
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/playwright
RUN set -e; \
    if [ "$XPAM_REPORT_PDF" = "1" ]; then \
      find /etc/apt -type f \( -name '*.sources' -o -name '*.list' \) -exec \
          sed -i -E 's#https?://mirrors\.(cloud\.)?aliyun(cs)?\.com#http://deb.debian.org#g' {} +; \
      apt-get update >/dev/null; \
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 libdbus-1-3 libdrm2 libgbm1 \
        libnspr4 libnss3 libx11-6 libxcb1 libxcomposite1 libxdamage1 libxext6 libxfixes3 libxi6 \
        libxkbcommon0 libxrandr2 libxrender1 \
        fontconfig-config fonts-liberation fonts-dejavu-core fonts-wqy-zenhei poppler-utils >/dev/null; \
      /usr/local/bin/uv pip install --python /opt/py3/bin/python "playwright==1.64.1"; \
      /opt/py3/bin/python -m playwright install --only-shell chromium; \
      shell="$(find "$PLAYWRIGHT_BROWSERS_PATH" -name chrome-headless-shell -type f)"; \
      if [ -z "$shell" ] || ldd "$shell" | grep -q 'not found'; then \
        echo "chrome-headless-shell missing or lacks libraries"; ldd "$shell" | grep 'not found'; exit 1; \
      fi; \
      rm -rf "$PLAYWRIGHT_BROWSERS_PATH"/ffmpeg-* /root/.cache; \
      apt-get clean && rm -rf /var/lib/apt/lists/*; \
    fi

# Packages of the base image no XPAM code uses: Alibaba OSS (removed), VMware and HashiCorp SDKs, an old
# Azure library and a build tool, with the dependencies only they need. pip check fails the build if any
# remaining package lost a requirement.
RUN /usr/local/bin/uv pip uninstall --python /opt/py3/bin/python \
        oss2 aliyun-python-sdk-kms aliyun-python-sdk-core pyvmomi hvac pyhcl msrestazure msrest adal \
        ansible-builder bindep \
    && /usr/local/bin/uv pip check --python /opt/py3/bin/python

# Security updates for the OS packages inherited from the upstream image (same Debian release)
# (the upstream image points apt at a mirror that is only reachable inside Alibaba Cloud)
# a new build date re-runs the system upgrade (otherwise the cached layer keeps old packages). It comes after the
# pinned Python packages: those layers stay the same from one release to the next, so an upgrade downloads
# the system updates and the code, not ~200 MB of unchanged packages again.
ARG APT_REFRESH=0
RUN find /etc/apt -type f \( -name '*.sources' -o -name '*.list' \) -exec \
        sed -i -E 's#https?://mirrors\.(cloud\.)?aliyun(cs)?\.com#http://deb.debian.org#g' {} + \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends upgrade \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Performance (tests/perf/bench_run.sh): psycopg 3 and its pool, so each process keeps PostgreSQL connections
# instead of opening one (~4 ms) per request (settings/base.py, DB_POOL_*; psycopg2 stays for the just-in-time
# target databases); httptools and uvloop, the C HTTP parser and event loop uvicorn uses when they are installed.
# (After the system layers: a few MB of wheels, so the large cached layers above are not rebuilt for them.)
RUN /usr/local/bin/uv pip install --python /opt/py3/bin/python \
        "psycopg[binary]==3.3.8" "psycopg-pool==3.3.3" "httptools==0.9.0" "uvloop==0.23.0" \
    && /usr/local/bin/uv pip check --python /opt/py3/bin/python

# The application code comes only from this repository: COPY adds and overwrites but never removes,
# so files XPAM deleted would otherwise linger from the base image (dead code, old templates, even the
# OIDC helper a security fix replaced). Keep only the data files the repository does not carry: the
# IP location databases, the leaked-password list and the compiled English translations (XPAM is
# English only; the base image's other languages are dropped too). Also remove upstream's leftover
# utils/* scripts, docs, readmes, requirements, ui, and source-map (.map) files. LICENSE stays: JumpServer is
# GPLv3, and the licence text must ship with the software built on it.
RUN cd /opt/jumpserver/apps \
    && find . -type f ! -path './i18n/core/en/LC_MESSAGES/*.mo' ! -name 'leak_passwords.db' \
         ! -name 'GeoLite2-City.mmdb' ! -name 'ipipfree.ipdb' -delete \
    && find . -mindepth 1 -depth -type d -empty -delete \
    && rm -rf /opt/jumpserver/utils /opt/jumpserver/docs /opt/jumpserver/readmes \
         /opt/jumpserver/requirements /opt/jumpserver/ui /opt/jumpserver/Dockerfile* \
         /opt/jumpserver/*.md /opt/jumpserver/config_example.yml \
         /opt/jumpserver/pyproject.toml /opt/jumpserver/uv.lock \
         /opt/jumpserver/.dockerignore /opt/jumpserver/.git* /opt/jumpserver/.isort.cfg \
         /opt/jumpserver/.prettierrc /opt/jumpserver/.pylintrc \
    && find /opt/jumpserver/.venv -name '*.map' -delete 2>/dev/null || true

# --- build stage: compile the Python application to native extension modules (.so) in a discarded
# stage so that plaintext .py sources, intermediate .pyc files, and the gcc/Cython toolchain never
# enter any layer of the final runtime image.
FROM base AS build
ARG XPAM_COMPILE=1
COPY apps /opt/jumpserver/apps
COPY --from=xpamscripts compile_py.sh /tmp/compile_py.sh
COPY --from=xpamscripts strip_docstrings.py /tmp/strip_docstrings.py
RUN set -e; \
    if [ "$XPAM_COMPILE" = "1" ]; then \
      find /etc/apt -type f \( -name '*.sources' -o -name '*.list' \) -exec \
        sed -i -E 's#https?://mirrors\.(cloud\.)?aliyun(cs)?\.com#http://deb.debian.org#g' {} + 2>/dev/null || true; \
      apt-get update >/dev/null && apt-get -y --no-install-recommends install gcc binutils >/dev/null; \
      /usr/local/bin/uv pip install --python /opt/py3/bin/python -q Cython setuptools; \
      mv /opt/jumpserver/apps /b; \
      JOBS="$(nproc)" PYBIN=/opt/py3/bin/python sh /tmp/compile_py.sh /b; \
      mv /b /opt/jumpserver/apps; \
      /opt/py3/bin/python -W ignore -m compileall -q -j 0 /opt/jumpserver/apps >/dev/null 2>&1 || true; \
    else \
      /opt/py3/bin/python -W ignore -m compileall -q -j 0 /opt/jumpserver/apps >/dev/null 2>&1 || true; \
    fi; \
    rm -f /tmp/compile_py.sh /tmp/strip_docstrings.py

# --- runtime stage
FROM base
COPY --from=build /opt/jumpserver/apps /opt/jumpserver/apps
# XPAM: the start script (quick start when nothing changed), runtime utils, and this build's identity
COPY jms /opt/jumpserver/jms
COPY utils/check_celery.sh /opt/jumpserver/utils/check_celery.sh
COPY utils/start_celery_beat.py /opt/jumpserver/utils/start_celery_beat.py
ARG XPAM_BUILD_ID=dev
RUN echo "${XPAM_BUILD_ID}" > /opt/jumpserver/BUILD_ID \
    && sed -i '/^[[:space:]]*#[^!]/d' /opt/jumpserver/entrypoint.sh \
    && chmod +x /opt/jumpserver/jms /opt/jumpserver/utils/check_celery.sh \
    && ln -sf check_celery.sh /opt/jumpserver/utils/check_worker.sh
