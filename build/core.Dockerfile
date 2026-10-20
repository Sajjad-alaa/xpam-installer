# XPAM core: official JumpServer v5.0.0 release image + XPAM code overlay.
# Build:  docker build -f core.Dockerfile -t xpam/core:<tag> /opt/xpam-core
# Official JumpServer v5.0.0-ce image, pinned by digest (same image on every build host)
FROM jumpserver/core@sha256:902c58566c5248f3752309c8fb34c2f61b1ba39bde54a7439b36115afb7fd16d

# Security updates for the OS packages inherited from the upstream image (same Debian release)
# (the upstream image points apt at a mirror that is only reachable inside Alibaba Cloud)
RUN find /etc/apt -type f \( -name '*.sources' -o -name '*.list' \) -exec \
        sed -i -E 's#https?://mirrors\.(cloud\.)?aliyun(cs)?\.com#http://deb.debian.org#g' {} + \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends upgrade \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Security upgrades for critical Python dependencies (FIX-08)
RUN /usr/local/bin/uv pip install --python /opt/py3/bin/python \
    "Django==5.2.17" "PyJWT==2.15.0" "urllib3==2.8.0" "requests==2.33.0" \
    "tornado==6.5.9" "pypdf==6.19.0" "werkzeug==3.1.3" "pymongo==4.18.2" \
    "cryptography==50.0.2" "pyOpenSSL==26.4.0" "mistune==3.3.4"

# Oracle driver (thin mode, no Oracle client needed): Oracle secret automations and
# just-in-time database accounts (upstream ships it only with the enterprise build)
RUN /usr/local/bin/uv pip install --python /opt/py3/bin/python "oracledb==3.4.2"

# Network device accounts (FortiGate, Palo Alto, Cisco, Juniper, Huawei, H3C): push, change secret,
# removal, discovery and just-in-time accounts (libs/ansible/modules_utils/network_device.py)
RUN /usr/local/bin/uv pip install --python /opt/py3/bin/python "netmiko==4.5.0"

COPY apps /opt/jumpserver/apps
# Compile the Python sources once at build time: faster first start, and the interpreter's
# warnings about old-style escape sequences do not show up in installation and upgrade logs
RUN /opt/py3/bin/python -W ignore -m compileall -q -j 0 /opt/jumpserver/apps >/dev/null 2>&1 || true
# The health check script under the name the worker container uses
RUN ln -sf check_celery.sh /opt/jumpserver/utils/check_worker.sh
