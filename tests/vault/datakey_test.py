"""
XPAM data keys: Vault Transit (the key never leaves Vault) and the local keyring — encryption, conversion of
older values, rotation without downtime, retirement of old versions, and what XPAM may not do with the key.

Run inside a core container on a THROWAWAY database:
    python /t/datakey_test.py transit     (XPAM_DATA_KEY=transit, Vault settings, XPAM_TEST_VAULT_ROOT_HDR file)
    python /t/datakey_test.py local       (XPAM_DATA_KEY=local)
"""
import json
import os
import sys
import uuid

sys.path.insert(0, '/opt/jumpserver/apps')
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'jumpserver.settings')
import django  # noqa: E402

django.setup()

from django.conf import settings  # noqa: E402
from django.db import connection, transaction  # noqa: E402

MODE = sys.argv[1]
results = []


def check(name, ok, detail=''):
    results.append(bool(ok))
    print(('PASS ' if ok else 'FAIL ') + f'[{MODE}] ' + name + ('' if ok else f'  ({detail})'), flush=True)


from accounts.models import Account  # noqa: E402
from assets.models import Host, Platform  # noqa: E402
from common.db import datakey  # noqa: E402
from common.db.utils import Encryptor  # noqa: E402
from common.utils import crypto  # noqa: E402
from orgs.models import Organization  # noqa: E402
from orgs.utils import tmp_to_org  # noqa: E402
from settings.tasks.datakey import data_key_status, rotate_data_keys  # noqa: E402


def raw_secret(account):
    with connection.cursor() as c:
        c.execute('SELECT _secret FROM accounts_account WHERE id = %s', [account.id])
        return c.fetchone()[0]


def set_raw(account, value):
    with connection.cursor() as c:
        c.execute('UPDATE accounts_account SET _secret = %s WHERE id = %s', [value, account.id])


with tmp_to_org(Organization.default()):
    with transaction.atomic():
        host = Host.objects.create(name=f'dk-{uuid.uuid4().hex[:4]}', address='192.0.2.41',
                                   platform=Platform.objects.get(name='Linux'), is_active=False)
    secret = 'canary-' + uuid.uuid4().hex
    acc = Account.objects.create(asset=host, name='dk-' + uuid.uuid4().hex[:4], username='dk-' + uuid.uuid4().hex[:4],
                                 secret_type='password', secret=secret)
    acc2 = Account.objects.create(asset=host, name='dk-' + uuid.uuid4().hex[:4], username='dk-' + uuid.uuid4().hex[:4],
                                  secret_type='password', secret=secret)

prefix = datakey.TRANSIT_PREFIX if MODE == 'transit' else datakey.LOCAL_PREFIX
raw = raw_secret(acc)
check('a new secret is stored only as ciphertext of the data key', raw.startswith(prefix) and secret not in raw, raw[:40])
check('XPAM reads it back', Account.objects.get(id=acc.id).secret == secret)
check('the same secret twice gives two different ciphertexts' + (' (a derived key per value)' if MODE == 'transit' else ''),
      raw_secret(acc2) != raw)

# an older value (SECRET_KEY) is converted by the daily task
legacy = crypto.encrypt('legacy-' + secret)
set_raw(acc2, legacy)
result = rotate_data_keys()
check('the daily task converts values encrypted the old way', raw_secret(acc2).startswith(prefix)
      and Account.objects.get(id=acc2.id).secret == 'legacy-' + secret, result)

v1 = datakey.version_of(raw_secret(acc))
old_copy = raw_secret(acc)

# rotation
if MODE == 'transit':
    import requests
    root_hdr = dict(l.split(': ', 1) for l in open(os.environ['XPAM_TEST_VAULT_ROOT_HDR']).read().splitlines() if l)
    vault = datakey.transit.client()
    url = vault.urls[0]
    s = requests.Session(); s.verify = settings.VAULT_HCP_CA_FILE
    s.cert = (settings.VAULT_HCP_CLIENT_CERT_FILE, settings.VAULT_HCP_CLIENT_KEY_FILE)
    r = s.post(f'{url}/v1/{datakey.transit.mount}/keys/{datakey.transit.key}/rotate', headers=root_hdr, json={})
    check('Vault rotates the key (here by hand; the kit sets every 7 days)', r.status_code in (200, 204), r.status_code)
else:
    datakey.keyring.rotate()
    check('the keyring makes a new key version', datakey.keyring.current()[0] == v1 + 1)
settings.XPAM_DATA_KEY_KEEP_VERSIONS = 1
datakey._opened.clear()
result = rotate_data_keys()
v2 = datakey.version_of(raw_secret(acc))
check('every value is re-encrypted with the new version, in place', v2 == v1 + 1
      and datakey.version_of(raw_secret(acc2)) == v2, result)
check('still readable — XPAM kept running, nobody signed out', Account.objects.get(id=acc.id).secret == secret)
check('the old version is retired (keep 1)', (result.get('oldest_kept') or 0) >= v2, result)
datakey._opened.clear()
try:
    Encryptor(old_copy).decrypt()
    retired = False
except datakey.DataKeyUnavailable:
    retired = True
check('an old copy (e.g. an old backup) no longer opens', retired)

status = data_key_status()
check('the console status shows the provider, version and values', status.get('provider') == MODE
      and status.get('version') == v2 and str(v2) in (status.get('values') or {}), status)

if MODE == 'transit':
    hdr = {'X-Vault-Token': vault._get_token()}
    base = f'{url}/v1/{datakey.transit.mount}'
    denied = {
        'export the key': s.get(f'{base}/export/encryption-key/{datakey.transit.key}', headers=hdr).status_code,
        'allow its deletion': s.post(f'{base}/keys/{datakey.transit.key}/config', headers=hdr,
                                     json={'deletion_allowed': True}).status_code,
        'trim old versions': s.post(f'{base}/keys/{datakey.transit.key}/trim', headers=hdr,
                                    json={'min_available_version': v2}).status_code,
        'delete it': s.delete(f'{base}/keys/{datakey.transit.key}', headers=hdr).status_code,
    }
    check('XPAM cannot export, trim or delete the key, nor allow its deletion',
          all(code == 403 for code in denied.values()), denied)
    # Vault unreachable: never an empty value
    fresh = Account.objects.get(id=acc.id)
    datakey._opened.clear()
    datakey.transit.reset()
    good_host = settings.VAULT_HCP_HOST
    settings.VAULT_HCP_HOST = 'https://127.0.0.1:1'
    try:
        Encryptor(raw_secret(fresh)).decrypt()
        refused = False
    except datakey.DataKeyUnavailable:
        refused = True
    settings.VAULT_HCP_HOST = good_host
    datakey.transit.reset()
    check('Vault unreachable: an error, never an empty password', refused)

if MODE == 'local':
    # SECRET_KEY rotation re-wraps the keyring: the values stay readable with the new key
    from django.core.management import call_command
    new_key = uuid.uuid4().hex + uuid.uuid4().hex
    os.environ['NEW_SECRET_KEY'] = new_key
    call_command('rotate_secret_key')
    settings.SECRET_KEY = new_key
    datakey._opened.clear()
    datakey.keyring._loaded = 0
    check('SECRET_KEY rotation re-wraps the keyring: still readable with the new key',
          Account.objects.get(id=acc.id).secret == secret)

print(f'RESULT [{MODE}]: {sum(results)}/{len(results)} passed', flush=True)
sys.exit(0 if all(results) else 1)
