# XPAM high availability: PostgreSQL managed by Patroni (leader election in etcd, streaming replication,
# automatic failover, pg_rewind of a former primary). Same PostgreSQL release as the single-server setup.
FROM postgres:16.15-bookworm
ARG APT_REFRESH=0
ARG PATRONI_VERSION=4.1.5
ARG PSYCOPG2_VERSION=2.9.13
RUN echo "apt refresh ${APT_REFRESH}" && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3-venv curl \
    && python3 -m venv /opt/patroni \
    && /opt/patroni/bin/pip install --no-cache-dir "patroni[etcd3]==${PATRONI_VERSION}" "psycopg2-binary==${PSYCOPG2_VERSION}" \
    && apt-get purge -y --auto-remove \
    && rm -rf /var/lib/apt/lists/*
COPY patroni-entrypoint.sh xpam-reload-certs /usr/local/bin/
RUN chmod 755 /usr/local/bin/patroni-entrypoint.sh /usr/local/bin/xpam-reload-certs
EXPOSE 5432 8008
HEALTHCHECK --interval=10s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -fsS --cacert /run/xpam-ha/ca.crt --cert /run/xpam-ha/node.crt --key /run/xpam-ha/node.key \
        https://127.0.0.1:8008/liveness >/dev/null || exit 1
ENTRYPOINT ["/usr/local/bin/patroni-entrypoint.sh"]
