# XPAM core: official JumpServer v5.0.0 release image + XPAM code overlay.
# Build:  docker build -f core.Dockerfile -t xpam/core:<tag> /opt/xpam-core
# Official JumpServer v5.0.0-ce image, pinned by digest (same image on every build host)
FROM jumpserver/core@sha256:902c58566c5248f3752309c8fb34c2f61b1ba39bde54a7439b36115afb7fd16d

# Security upgrades for critical Python dependencies (FIX-08)
RUN /usr/local/bin/uv pip install --python /opt/py3/bin/python \
    "Django==5.2.17" "PyJWT==2.15.0" "urllib3==2.8.0" "requests==2.33.0" \
    "tornado==6.5.9" "pypdf==6.19.0" "werkzeug==3.1.3"

COPY apps /opt/jumpserver/apps
# The health check script under the name the worker container uses
RUN ln -sf check_celery.sh /opt/jumpserver/utils/check_worker.sh
