# XPAM core: built on the official JumpServer v5.0.0 release image (its Python environment and system packages),
# with XPAM's own code, names and paths. Stages: prep (packages; moved to /opt/core) -> base (one clean layer,
# no upstream layers, history or labels) -> build (compile) -> the runtime image.
# Build:  docker build -f core.Dockerfile -t xpam/core:<tag> /opt/xpam-core
# Official JumpServer v5.0.0-ce image, pinned by digest (same image on every build host)
FROM jumpserver/core@sha256:902c58566c5248f3752309c8fb34c2f61b1ba39bde54a7439b36115afb7fd16d AS prep

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

# Performance (tests/perf/bench_run.sh): psycopg 3 and its pool, so each process keeps PostgreSQL connections
# instead of opening one (~4 ms) per request (settings/base.py, DB_POOL_*; psycopg2 stays for the just-in-time
# target databases); httptools and uvloop, the C HTTP parser and event loop uvicorn uses when they are installed.
RUN /usr/local/bin/uv pip install --python /opt/py3/bin/python \
        "psycopg[binary]==3.3.8" "psycopg-pool==3.3.3" "httptools==0.9.0" "uvloop==0.23.0" \
    && /usr/local/bin/uv pip check --python /opt/py3/bin/python

# Security upgrades of 2026-11-12 (Trivy): Pillow (heap overflows in its image decoders: uploaded logos, captcha),
# pypdf, Django REST framework, pyasn1, certifi (distrusted emSign roots), dnspython, msgpack, pymongo and oauthlib.
# python-ldap's test helper (slapdtest, with its sample private keys) is not used at run time.
RUN /usr/local/bin/uv pip install --python /opt/py3/bin/python \
        "pillow==13.0.0" "pypdf==6.21.4" "djangorestframework==3.18.2" "pyasn1==0.6.5" "certifi==2026.10.18" \
        "dnspython==2.9.0" "msgpack==1.2.3" "pymongo==4.18.3" "oauthlib==4.0.1" \
    && /usr/local/bin/uv pip check --python /opt/py3/bin/python \
    && rm -rf "$(/opt/py3/bin/python -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')/slapdtest"

# The installation folder is /opt/core (the upstream image uses /opt/jumpserver), and the application code comes
# only from this repository: of the upstream tree only the data files the repository does not carry are kept — the
# IP location databases and the leaked-password list (the English messages are compiled from this repository's .po in
# the build stage; XPAM is English only). The
# upstream start scripts, utils, docs and build files go; LICENSE stays (JumpServer is GPLv3: the licence text
# ships with the software built on it). Everything that names the old folder follows the move: the virtual
# environment (script shebangs, activate scripts, prompt; its bytecode is rebuilt so no old path is embedded) and
# Ansible's module library path. The step fails if the old folder is still named anywhere outside package data.
RUN set -e; \
    cd /opt/jumpserver/apps; \
    find . -type f ! -name 'leak_passwords.db' \
         ! -name 'GeoLite2-City.mmdb' ! -name 'ipipfree.ipdb' -delete; \
    find . -mindepth 1 -depth -type d -empty -delete; \
    cd /; \
    rm -rf /opt/jumpserver/utils /opt/jumpserver/docs /opt/jumpserver/readmes /opt/jumpserver/requirements \
         /opt/jumpserver/ui /opt/jumpserver/Dockerfile* /opt/jumpserver/*.md /opt/jumpserver/config_example.yml \
         /opt/jumpserver/pyproject.toml /opt/jumpserver/uv.lock /opt/jumpserver/.dockerignore /opt/jumpserver/.git* \
         /opt/jumpserver/.isort.cfg /opt/jumpserver/.prettierrc /opt/jumpserver/.pylintrc \
         /opt/jumpserver/jms /opt/jumpserver/entrypoint.sh /opt/jumpserver/BUILD_ID; \
    find /opt/jumpserver/.venv -name '*.map' -delete 2>/dev/null || true; \
    mv /opt/jumpserver /opt/core; \
    ln -sfn /opt/core/.venv /opt/py3; \
    grep -rIl '/opt/jumpserver' /opt/core/.venv/bin /opt/core/.venv/pyvenv.cfg /etc /root /usr/local/bin 2>/dev/null \
      | xargs -r sed -i 's#/opt/jumpserver#/opt/core#g'; \
    sed -i 's#^prompt = .*#prompt = xpam#' /opt/core/.venv/pyvenv.cfg; \
    grep -rIl --include='*.pth' --include='direct_url.json' --include='RECORD' '/opt/jumpserver' /opt/core/.venv/lib 2>/dev/null \
      | xargs -r sed -i 's#/opt/jumpserver#/opt/core#g'; \
    find /opt/core/.venv -name '*.pyc' -delete; \
    /opt/py3/bin/python -W ignore -m compileall -q -j 0 /opt/py3/lib >/dev/null 2>&1 || true; \
    /opt/py3/bin/python -c "import django, ansible, celery, gunicorn; print('environment ok after the move')"; \
    /opt/py3/bin/gunicorn --version; /opt/py3/bin/celery --version; \
    grep -q '/opt/core/apps/libs/ansible/modules' /etc/ansible/ansible.cfg; \
    if grep -rIl '/opt/jumpserver' /etc /root /usr/local/bin /opt/core --exclude-dir=site-packages 2>/dev/null | grep .; then \
      echo 'the old folder is still named in the files above'; exit 1; \
    fi; \
    if grep -rl '/opt/jumpserver' /opt/core/.venv --include='*.pyc' 2>/dev/null | head -3 | grep .; then \
      echo 'bytecode still embeds the old folder'; exit 1; \
    fi

# --- base: the prepared system as one clean layer. Nothing of the upstream image's layers, build history or labels
# is carried over; this layer stays the same from one release to the next (an upgrade downloads only what follows).
FROM scratch AS base
COPY --from=prep / /
ENV PATH=/opt/py3/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin \
    LANG=en_US.UTF-8 \
    PLAYWRIGHT_BROWSERS_PATH=/opt/playwright
WORKDIR /opt/core

# Security updates for the OS packages (same Debian release). A new build date re-runs the upgrade (otherwise the
# cached layer keeps old packages). (The upstream image points apt at a mirror only reachable inside Alibaba Cloud.)
ARG APT_REFRESH=0
RUN find /etc/apt -type f \( -name '*.sources' -o -name '*.list' \) -exec \
        sed -i -E 's#https?://mirrors\.(cloud\.)?aliyun(cs)?\.com#http://deb.debian.org#g' {} + \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends upgrade \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# --- build stage: compile the Python application to native extension modules (.so) in a discarded
# stage so that plaintext .py sources, intermediate .pyc files, and the gcc/Cython toolchain never
# enter any layer of the final runtime image.
FROM base AS build
ARG XPAM_COMPILE=1
COPY apps /opt/core/apps
COPY --from=xpamscripts compile_py.sh /tmp/compile_py.sh
COPY --from=xpamscripts strip_docstrings.py /tmp/strip_docstrings.py
RUN set -e; \
    apt-get update >/dev/null && apt-get -y --no-install-recommends install gettext >/dev/null; \
    for po in /opt/core/apps/i18n/core/en/LC_MESSAGES/*.po; do msgfmt --check -o "${po%.po}.mo" "$po" 2>/dev/null; done; \
    ls /opt/core/apps/i18n/core/en/LC_MESSAGES/django.mo /opt/core/apps/i18n/core/en/LC_MESSAGES/djangojs.mo >/dev/null; \
    if [ "$XPAM_COMPILE" = "1" ]; then \
      apt-get -y --no-install-recommends install gcc binutils >/dev/null; \
      /usr/local/bin/uv pip install --python /opt/py3/bin/python -q Cython setuptools; \
      mv /opt/core/apps /b; \
      JOBS="$(nproc)" PYBIN=/opt/py3/bin/python sh /tmp/compile_py.sh /b; \
      mv /b /opt/core/apps; \
      /opt/py3/bin/python -W ignore -m compileall -q -j 0 /opt/core/apps >/dev/null 2>&1 || true; \
    else \
      /opt/py3/bin/python -W ignore -m compileall -q -j 0 /opt/core/apps >/dev/null 2>&1 || true; \
    fi; \
    rm -f /tmp/compile_py.sh /tmp/strip_docstrings.py

# --- runtime stage
FROM base
COPY --from=build /opt/core/apps /opt/core/apps
# The launcher (`python xpam start web|task|all`; quick start when nothing changed), the entry point, the worker's
# health check and beat starter, and this build's identity
COPY xpam /opt/core/xpam
COPY --chmod=755 entrypoint.sh /opt/core/entrypoint.sh
COPY utils/check_celery.sh utils/start_celery_beat.py /opt/core/utils/
ARG XPAM_BUILD_ID=dev
RUN echo "${XPAM_BUILD_ID}" > /opt/core/BUILD_ID \
    && chmod +x /opt/core/xpam /opt/core/utils/check_celery.sh \
    && ln -sf check_celery.sh /opt/core/utils/check_worker.sh \
    && mkdir -p /opt/core/data /opt/core/tmp
EXPOSE 8080
STOPSIGNAL SIGQUIT
ENTRYPOINT ["./entrypoint.sh"]
CMD ["start", "all"]
