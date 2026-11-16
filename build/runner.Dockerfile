# XPAM runner: runs the jobs users write, away from core (build/runner/server.py). Built on the core image of the
# same release for its Python environment, Ansible (with the hardening of build/ansible_hardening.py), SSH, sshpass
# and the database drivers; the application itself, its data and the report browser are removed.
#   docker build -f runner.Dockerfile --build-arg CORE_IMAGE=xpam/core:<tag> -t xpam/runner:<tag> build/runner
ARG CORE_IMAGE
FROM ${CORE_IMAGE}
ARG RUNNER_USERS=16
RUN set -e; \
    find /opt/core/apps -mindepth 1 -maxdepth 1 ! -name libs -exec rm -rf {} +; \
    find /opt/core/apps/libs -mindepth 1 -maxdepth 1 ! -name ansible ! -name __init__.py -exec rm -rf {} +; \
    rm -rf /opt/core/data /opt/core/xpam /opt/core/entrypoint.sh /opt/core/utils /opt/core/BUILD_ID /opt/playwright \
           /root/.ansible /root/.cache; \
    mkdir -p /opt/core/data/share/ansible /opt/runner; \
    test -f /opt/py3/lib/python3.14/site-packages/ansible/xpam_guard.py; \
    for n in $(seq 1 "$RUNNER_USERS"); do \
      useradd --uid $((20000 + n)) --user-group --no-create-home --home-dir "/tmp/home/runner$n" --shell /usr/sbin/nologin "runner$n"; \
    done; \
    /opt/py3/bin/ansible-runner --version
COPY --chmod=644 server.py ansible.cfg /opt/runner/
ENV RUNNER_MAX_JOBS=4 PYTHONUNBUFFERED=1
WORKDIR /opt/runner
EXPOSE 8086
HEALTHCHECK --interval=15s --timeout=5s --retries=3 --start-period=10s \
    CMD ["/opt/py3/bin/python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8086/health', timeout=4)"]
ENTRYPOINT ["/opt/py3/bin/python", "/opt/runner/server.py"]
