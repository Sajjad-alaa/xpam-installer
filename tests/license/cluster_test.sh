#!/usr/bin/env bash
# The cluster licence (one company's high availability cluster): bound to the cluster's database seed and to
# the servers it lists — an unlisted server gets trial limits at once; single-server licences unchanged.
# Runs XPAM's core on a throwaway database. Licences are signed by the real generator with a throwaway key
# (never the vendor key); core is pointed at that key's public half for the test.
#   tests/license/cluster_test.sh [tag]        (GENERATOR: path of generate_license.py, default /opt/generate_license.py)
set -uo pipefail
TAG=${1:-v5.1.17}
GENERATOR=${GENERATOR:-/opt/generate_license.py}
NET=lctnet
cleanup() { docker rm -f lctpg lctredis lctcore >/dev/null 2>&1; docker network rm $NET >/dev/null 2>&1; }
trap cleanup EXIT
cleanup
rnd() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
W=$(mktemp -d)
cat > "$W/env" <<EOF
SECRET_KEY=$(rnd)$(rnd)
BOOTSTRAP_TOKEN=$(rnd)
DB_ENGINE=postgresql
DB_HOST=lctpg
DB_PORT=5432
DB_USER=postgres
DB_PASSWORD=$(rnd)
DB_NAME=jumpserver
REDIS_HOST=lctredis
REDIS_PORT=6379
REDIS_PASSWORD=$(rnd)
EOF
. "$W/env"
docker network create $NET >/dev/null
docker run -d --name lctpg --network $NET -e POSTGRES_PASSWORD="$DB_PASSWORD" -e POSTGRES_DB=jumpserver postgres:16.15-bookworm >/dev/null
docker run -d --name lctredis --network $NET redis:7.4.10-bookworm redis-server --requirepass "$REDIS_PASSWORD" >/dev/null
sleep 5
docker run -d --name lctcore --network $NET --env-file "$W/env" "xpam/core:$TAG" start web >/dev/null
rm -rf "$W"
for _ in $(seq 1 120); do
  docker exec lctcore python3 -c "import urllib.request as u; u.urlopen('http://127.0.0.1:8080/api/health/', timeout=2)" >/dev/null 2>&1 && break
  sleep 3
done
docker cp "$GENERATOR" lctcore:/tmp/gen.py
docker exec -i lctcore bash -c 'cd /opt/jumpserver/apps && python manage.py shell 2>/dev/null' <<'PY'
import base64, json, subprocess, sys
from unittest import mock
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ed25519
import xpack.utils as U

PASS = FAIL = 0
def check(name, ok):
    global PASS, FAIL
    print(('PASS ' if ok else 'FAIL ') + name)
    PASS, FAIL = PASS + bool(ok), FAIL + (not ok)

key = ed25519.Ed25519PrivateKey.generate()
with open('/tmp/test-key.pem', 'wb') as f:
    f.write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                              serialization.NoEncryption()))
U.get_license_public_key = lambda: key.public_key()

def gen(*args):
    r = subprocess.run([sys.executable, '/tmp/gen.py', '-k', '/tmp/test-key.pem', '-o', '/tmp/l.lic',
                        '-u', '50', '-a', '200', *args], capture_output=True, text=True)
    return r.returncode, (open('/tmp/l.lic').read() if r.returncode == 0 else r.stderr + r.stdout)

def sign(payload):
    sig = key.sign(json.dumps(payload, sort_keys=True, separators=(',', ':')).encode())
    return base64.b64encode(json.dumps({'data': payload, 'signature': base64.b64encode(sig).decode()}).encode()).decode()

def install(lic):
    payload, err = U.verify_license_content(lic, enforce_installation=True, expected_type='license')
    if payload:
        U.save_license_data(payload, raw_license=lic)
    return err

def info():
    return U.get_current_license_info(force_refresh=True)

def as_server(hw):
    U._CACHED_INST_ID = None
    return mock.patch.object(U, 'get_hardware_uuid', return_value=hw)

CL = U.get_cluster_id()
with as_server('hardware-of-server-a'):
    SA = U.get_server_id()
with as_server('hardware-of-server-b'):
    SB = U.get_server_id()
print('ids', CL, SA, SB)
check('IDs have the documented form', CL.startswith('CL-') and len(CL) == 22 and SA.startswith('SRV-') and SA != SB)

# a licence for server A only (the generator, as the vendor uses it)
rc, lic_a = gen('--cluster-id', CL, '--servers', SA)
check('the generator issues a cluster licence', rc == 0)
with as_server('hardware-of-server-a'):
    check('server A imports it', install(lic_a) is None)
    i = info()
    check('on server A it is valid with its limits (50 users)', i['is_valid'] and i['user_limit'] == 50)
    check('the console sees the cluster ID, server ID and licensed servers',
          i['current_cluster_id'] == CL and i['current_server_id'] == SA and i.get('servers') == [SA])
with as_server('hardware-of-server-b'):
    i = info()
    check('on server B (not listed) it is refused at once: trial limits',
          not i['is_valid'] and i['status'] == 'Invalid (Host Mismatch)' and i['user_limit'] == 2)
    check('the message names server B and says what to do', SB in i['remark'] and 'vendor' in i['remark'])
    check('server B cannot import it either', 'not in the license' in (install(lic_a) or ''))

# one licence for both servers of the cluster
rc, lic_ab = gen('--cluster-id', CL, '--servers', f'{SA},{SB}')
with as_server('hardware-of-server-a'):
    check('a licence for A and B imports', rc == 0 and install(lic_ab) is None)
    check('valid on A', info()['is_valid'])
with as_server('hardware-of-server-b'):
    check('valid on B (after a failover)', info()['is_valid'])
with as_server('hardware-of-server-c'):
    check('refused on an unlisted server C', not info()['is_valid'])

# another company's installation (another database seed) cannot use it
with as_server('hardware-of-server-a'):
    other = 'CL-' + '-'.join(['ABCD'] * 4)
    rc, lic_other = gen('--cluster-id', other, '--servers', SA)
    check("another company's cluster licence is refused here", rc == 0 and 'cluster' in (install(lic_other) or ''))
    with mock.patch.object(U, 'get_installation_seed', return_value='ANOTHER-DATABASE'):
        check('this licence on a copy with another database seed is refused', not info()['is_valid'])

# limits on the number of servers
rc, out = gen('--cluster-id', CL, '--servers', f'{SA},{SB},SRV-0000-0000-0000')
check('the generator refuses 3 servers with the default maximum (2)', rc != 0 and 'max-servers' in out)
rc, lic3 = gen('--cluster-id', CL, '--servers', f'{SA},{SB},SRV-0000-0000-0000', '--max-servers', '3')
check('with --max-servers 3 it issues one', rc == 0)
rc, out = gen('--cluster-id', 'CL-NOT-AN-ID', '--servers', SA)
check('the generator refuses a malformed cluster ID', rc != 0)
base = {'type': 'license', 'license_id': 'x', 'serial_no': 'XPAM-LIC-T', 'installation_id': CL, 'user_limit': 9,
        'asset_count': 9, 'date_expired': 'Never', 'cluster_id': CL}
with as_server('hardware-of-server-a'):
    check('a signed licence with a wildcard server is refused',
          install(sign({**base, 'servers': ['*', SA], 'max_servers': 2})) is not None)
    check('a signed licence listing more servers than it allows is refused',
          install(sign({**base, 'servers': [SA, SB, 'SRV-0000-0000-0000'], 'max_servers': 2})) is not None)
    check('a signed licence without servers in the list is refused',
          install(sign({**base, 'servers': [], 'max_servers': 2})) is not None)

# single-server licences: unchanged
with as_server('hardware-of-server-a'):
    inst_a = U.get_system_installation_id()
    rc, lic_single = gen('-i', inst_a)
    check('a single-server licence still imports and is valid', rc == 0 and install(lic_single) is None and info()['is_valid'])
with as_server('hardware-of-server-b'):
    check('and is still refused on another server', not info()['is_valid'])
    rc, lic_wrong = gen('-i', 'INST-0000-0000-0000-0000')
    check('a licence for another installation ID is refused', 'mismatch' in (install(lic_wrong) or ''))

print(f'RESULT: {PASS}/{PASS + FAIL} passed')
PY
