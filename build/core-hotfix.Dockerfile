# XPAM core, hotfix build: the previous release's image with only the changed Python modules compiled anew, for a
# fix that must not wait for a full build (core.Dockerfile downloads ~700 MB of packages when nothing is cached).
# The result has what a full build of the same sources has: the same base system, the changed modules as compiled
# extension modules (same compile script and options), the Ansible limits (ansible_hardening.py) and its own build
# identity. Use it only when the change is limited to Python modules under apps/; the next full build replaces it.
#   docker build -f core-hotfix.Dockerfile --build-context xpamscripts=<installer>/build \
#     --build-arg FROM_IMAGE=xpam/core:v5.1.40 --build-arg XPAM_BUILD_ID=... \
#     --build-arg MODULES="ops/models/job.py ops/serializers/job.py" -t xpam/core:v5.1.41 /opt/xpam-core
# (build-all.sh core-hotfix does this with the modules changed since the previous release's tag)
ARG FROM_IMAGE
# any image of the core's Debian release (13) with gcc: only its C compiler is used
ARG TOOLCHAIN_IMAGE=golang:1.26-trixie
# an image with the same ansible-core unchanged (a core image from before 5.1.41): the Ansible limits are applied to
# a clean copy, so a newer ansible_hardening.py takes effect on a hotfix too
ARG STOCK_ANSIBLE_IMAGE
FROM ${FROM_IMAGE} AS previous
FROM ${STOCK_ANSIBLE_IMAGE} AS stockansible

# the compiler, Cython and gettext, kept as their own layer (built once per previous release)
FROM ${TOOLCHAIN_IMAGE} AS tools
COPY --from=previous /usr/local /usr/local
COPY --from=previous /opt/core/.venv /opt/core/.venv
RUN set -e; ln -sfn /opt/core/.venv /opt/py3; \
    apt-get update >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends gettext >/dev/null; \
    /usr/local/bin/uv pip install --python /opt/py3/bin/python -q Cython setuptools

FROM tools AS build
COPY apps /src
COPY --from=xpamscripts compile_py.sh strip_docstrings.py /tmp/
# MODULES: the changed files under apps/: Python modules are compiled; __init__.py files and migrations are kept as
# source (as compile_py.sh keeps them); translation sources (.po) are compiled to .mo
ARG MODULES
RUN set -e; \
    test -n "$MODULES"; mkdir /b /out; cd /src; \
    for m in $MODULES; do \
      case "$m" in *.po) continue ;; esac; \
      d="$(dirname "$m")"; mkdir -p "/b/$d"; cp "$m" "/b/$m"; \
      while [ "$d" != "." ]; do cp "$d/__init__.py" "/b/$d/__init__.py"; d="$(dirname "$d")"; done; \
    done; \
    JOBS="$(nproc)" PYBIN=/opt/py3/bin/python sh /tmp/compile_py.sh /b; \
    for m in $MODULES; do \
      mkdir -p "/out/$(dirname "$m")"; \
      case "$m" in \
        *.po) msgfmt --check -o "/out/${m%.po}.mo" "/src/$m" 2>/dev/null; continue ;; \
        */__init__.py|*/migrations/*) cp "/b/$m" "/out/$m"; continue ;; \
      esac; \
      so="$(cd /b && ls "${m%.py}".*.so 2>/dev/null | head -1)"; \
      if [ -z "$so" ]; then echo "core-hotfix: $m was not compiled"; exit 1; fi; \
      cp "/b/$so" "/out/$so"; \
    done; \
    find /out -type f | sort

FROM previous
COPY --from=xpamscripts ansible_hardening.py /tmp/ansible_hardening.py
COPY --from=stockansible /opt/py3/lib/python3.14/site-packages/ansible /tmp/stock-ansible
RUN set -e; \
    ansible_dir="$(/opt/py3/bin/python -c 'import ansible, os; print(os.path.dirname(ansible.__file__))')"; \
    test ! -f /tmp/stock-ansible/xpam_guard.py; \
    grep -q "$(grep '^__version__' "$ansible_dir/release.py")" /tmp/stock-ansible/release.py; \
    rm -rf "$ansible_dir"; mv /tmp/stock-ansible "$ansible_dir"; \
    /opt/py3/bin/python /tmp/ansible_hardening.py "$ansible_dir"; \
    /opt/py3/bin/python -W ignore -m compileall -q "$ansible_dir" >/dev/null 2>&1 || true; \
    /opt/py3/bin/python /tmp/ansible_hardening.py --check /opt/py3/bin/ansible; \
    rm -rf /tmp/ansible_hardening.py /root/.ansible
COPY --from=build /out/ /opt/core/apps/
ARG XPAM_BUILD_ID=dev
RUN echo "${XPAM_BUILD_ID}" > /opt/core/BUILD_ID \
    && cd /opt/core/apps && /opt/py3/bin/python -c "import os, django; os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'xpam.settings'); print('BUILD', open('/opt/core/BUILD_ID').read().strip())"
