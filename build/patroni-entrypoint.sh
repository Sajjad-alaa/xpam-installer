#!/bin/bash
# XPAM high availability: start PostgreSQL under Patroni. The configuration comes from the environment
# (config.txt) and the certificates mounted at /etc/xpam-ha; nothing secret is written to the image.
set -euo pipefail

: "${HA_NODE_NAME:?}" "${HA_NODE_IP:?}" "${HA_PEER_IP:?}" "${HA_WITNESS_IP:?}"
: "${DB_USER:?}" "${DB_PASSWORD:?}" "${HA_REPL_PASSWORD:?}" "${HA_PATRONI_PASSWORD:?}" "${HA_REWIND_PASSWORD:?}"

RUN=/run/xpam-ha
DATA=/var/lib/postgresql/data
install -d -m 0700 -o postgres -g postgres "$RUN"
for f in ca.crt node.crt node.key client.crt client.key; do
  [[ -f "/etc/xpam-ha/$f" ]] || continue
  install -m 0600 -o postgres -g postgres "/etc/xpam-ha/$f" "$RUN/$f"
done
mkdir -p "$DATA" && chown postgres:postgres "$DATA" && chmod 0700 "$DATA"

umask 077
/opt/patroni/bin/python - <<'PY'
import json, os
e = os.environ
ip, peer, witness = e['HA_NODE_IP'], e['HA_PEER_IP'], e['HA_WITNESS_IP']
run = '/run/xpam-ha'
subnet = e.get('DOCKER_SUBNET') or '192.168.250.0/24'
user = e['DB_USER']
client = 'client' if os.path.exists(f'{run}/client.crt') else 'node'
tls = {'sslmode': 'verify-ca', 'sslcert': f'{run}/node.crt', 'sslkey': f'{run}/node.key', 'sslrootcert': f'{run}/ca.crt'}
params = {
    'wal_level': 'replica', 'hot_standby': 'on', 'wal_log_hints': 'on', 'max_wal_senders': 10,
    'max_replication_slots': 10, 'wal_keep_size': '1GB', 'max_connections': int(e.get('HA_PG_MAX_CONNECTIONS') or 500),
    'password_encryption': 'scram-sha-256', 'ssl': 'on', 'ssl_cert_file': f'{run}/node.crt',
    'ssl_key_file': f'{run}/node.key', 'ssl_ca_file': f'{run}/ca.crt',
}
config = {
    'scope': 'xpam', 'namespace': '/xpam/', 'name': e['HA_NODE_NAME'],
    'log': {'level': 'INFO'},
    # the REST API: TLS, every call needs a client certificate of the cluster CA (also the status pages);
    # changes need the password too. Patroni's own calls to the other server use the ctl certificate.
    'restapi': {
        'listen': '0.0.0.0:8008', 'connect_address': f'{ip}:8008',
        'certfile': f'{run}/node.crt', 'keyfile': f'{run}/node.key', 'cafile': f'{run}/ca.crt',
        'verify_client': 'required',
        'authentication': {'username': 'patroni', 'password': e['HA_PATRONI_PASSWORD']},
    },
    'ctl': {'certfile': f'{run}/node.crt', 'keyfile': f'{run}/node.key', 'cacert': f'{run}/ca.crt'},
    # the vote: mutual TLS, and the account xpam-node (the only one allowed to read and write XPAM's
    # records; the witness's certificate has no account)
    'etcd3': {
        'hosts': [f'{h}:2379' for h in (ip, peer, witness)], 'protocol': 'https',
        'cacert': f'{run}/ca.crt', 'cert': f'{run}/{client}.crt', 'key': f'{run}/{client}.key',
        **({'username': 'xpam-node', 'password': e['HA_ETCD_PASSWORD']} if e.get('HA_ETCD_PASSWORD') else {}),
    },
    'bootstrap': {
        'dcs': {
            # failover in about 20 s (ttl >= loop_wait + 2 * retry_timeout); HA_PATRONI_TTL & co. to change it
            'ttl': int(e.get('HA_PATRONI_TTL') or 20), 'loop_wait': int(e.get('HA_PATRONI_LOOP_WAIT') or 5),
            'retry_timeout': int(e.get('HA_PATRONI_RETRY_TIMEOUT') or 5), 'maximum_lag_on_failover': 1048576,
            # no committed transaction is lost in a failover while both servers are healthy; with the
            # standby down the primary keeps working (not strict)
            'synchronous_mode': e.get('HA_SYNC', '1') == '1', 'synchronous_mode_strict': False,
            # no failsafe mode: with the witness, a primary that loses the vote (etcd quorum) must step
            # down — failsafe kept a cut-off primary running on a stale member list (split brain)
            'failsafe_mode': False,
            'postgresql': {'use_pg_rewind': True, 'use_slots': True, 'parameters': params},
        },
        'initdb': ['encoding=UTF8', 'data-checksums'],
    },
    'postgresql': {
        'listen': '0.0.0.0:5432', 'connect_address': f'{ip}:5432',
        'data_dir': '/var/lib/postgresql/data', 'bin_dir': '/usr/lib/postgresql/16/bin',
        'pgpass': f'{run}/pgpass', 'parameters': params,
        # the other server connects only as replicator (replication) and xpam_rewind (the four functions
        # pg_rewind reads), each with a password AND a client certificate of the cluster CA; XPAM's own
        # account (a superuser) is reachable from XPAM's containers only
        'authentication': {
            'superuser': {'username': user, 'password': e['DB_PASSWORD']},
            'replication': {'username': 'replicator', 'password': e['HA_REPL_PASSWORD'], **tls},
            'rewind': {'username': 'xpam_rewind', 'password': e['HA_REWIND_PASSWORD'], **tls},
        },
        'pg_hba': [
            'local all all trust',
            'host all all 127.0.0.1/32 scram-sha-256',
            f'host all {user} {subnet} scram-sha-256',
            'host replication replicator 127.0.0.1/32 scram-sha-256',  # (Patroni reads its own position)
            f'hostssl replication replicator {peer}/32 scram-sha-256 clientcert=verify-ca',
            f'hostssl postgres xpam_rewind {peer}/32 scram-sha-256 clientcert=verify-ca',
        ],
        'create_replica_methods': ['basebackup'],
        'basebackup': [{'checkpoint': 'fast'}],
        'remove_data_directory_on_rewind_failure': True,
        'remove_data_directory_on_diverged_timelines': True,
    },
    # xpam_version: the XPAM version installed on this server (xpamctl ha upgrade, ha status);
    # xpam_server_id: its ID for the cluster licence (shown in the console; the licence checks the hardware)
    'tags': {'nofailover': False, 'noloadbalance': False, 'clonefrom': False, 'nosync': False,
             'xpam_version': e.get('XPAM_VERSION', ''), 'xpam_server_id': e.get('XPAM_SERVER_ID', '')},
}
with open(f'{run}/patroni.yml', 'w') as f:
    json.dump(config, f)  # (JSON is valid YAML)
PY
chown postgres:postgres "$RUN/patroni.yml"

# A server without data never starts a cluster of its own (that would split XPAM into two databases):
# it waits for the primary and copies it. Only the converted single server (with data) can lead first.
if [[ ! -s "$DATA/PG_VERSION" ]]; then
  until curl -fsS -o /dev/null --max-time 3 --cacert "$RUN/ca.crt" --cert "$RUN/node.crt" --key "$RUN/node.key" \
      "https://${HA_PEER_IP}:8008/primary"; do
    echo "No data yet: waiting for the primary on ${HA_PEER_IP} to copy it..."
    sleep 5
  done
fi
exec gosu postgres /opt/patroni/bin/patroni "$RUN/patroni.yml"
