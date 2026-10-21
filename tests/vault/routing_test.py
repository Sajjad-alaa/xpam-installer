"""
XPAM with several vaults: storage rules (per organization, asset group, username), mirrors, moving secrets
when rules change, passwords read from an existing vault, and the console lock.

Run inside a core container on a THROWAWAY database, with the configured vault (HashiCorp) in the environment and
XPAM_TEST_CONNECTIONS = {"conjur": {"type": "cyberark", "config": {...}}, "delinea": ..., "gcp": ...}:
    python /t/routing_test.py
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
from django.db import transaction  # noqa: E402

results = []


def check(name, ok, detail=''):
    results.append(bool(ok))
    print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else f'  ({detail})'), flush=True)


from accounts.backends import refresh_vault_client, vault_client  # noqa: E402
from accounts.models import Account, VaultConnection, VaultStorageRule  # noqa: E402
from accounts.models.mixins.vault import VAULT_SAVED_SECRET_MARK  # noqa: E402
from accounts.tasks.vault_routing import move_secrets_by_rules  # noqa: E402
from assets.models import Host, Node, Platform  # noqa: E402
from common.db.utils import Encryptor  # noqa: E402
from orgs.models import Organization  # noqa: E402
from orgs.utils import tmp_to_org  # noqa: E402

from orgs.utils import tmp_to_root_org  # noqa: E402
with tmp_to_root_org():
    VaultStorageRule.objects.all().delete()  # (a previous run on the same database)
connections = {}
for name, spec in json.loads(os.environ['XPAM_TEST_CONNECTIONS']).items():
    VaultConnection.objects.filter(name=name).delete()
    connections[name] = VaultConnection.objects.create(name=name, type=spec['type'], config=spec['config'], managed=True)


def current():
    vault_client.type  # noqa: B018  (set up the lazy client again after a refresh)
    return vault_client._wrapped


refresh_vault_client()
router = current()
check('the router is in front of the configured vault', router.__class__.__name__ == 'VaultRouter' and router.type == 'hcp')


def raw(account, connection=None):
    """ what a vault holds for this account (encrypted with SECRET_KEY), '' when nothing """
    backend = router.backend(connection.id if connection else None)
    entry = backend.build_entry(account)
    try:
        if backend.type == 'hcp':
            return (backend.client.get(path=entry.full_path).get('data') or {}).get('secret') or ''
        return backend.client.get(name=entry.full_path) or ''
    except Exception:
        return ''


def holds(account, connection, value):
    return Encryptor(raw(account, connection) or '').decrypt() == value


def fresh(account):
    return Account.objects.get(id=account.id)


linux = Platform.objects.get(name='Linux')
default_org = Organization.default()
with tmp_to_org(default_org), transaction.atomic():
    root = Node.org_root()
    network = root.create_child(value='Network-' + uuid.uuid4().hex[:4])
    server = Host.objects.create(name='srv-' + uuid.uuid4().hex[:4], address='192.0.2.31', platform=linux, is_active=False)
    device = Host.objects.create(name='dev-' + uuid.uuid4().hex[:4], address='192.0.2.32', platform=linux, is_active=False)
    device.nodes.set([network])
org_b = Organization.objects.create(name='OrgB-' + uuid.uuid4().hex[:4])
with tmp_to_org(org_b), transaction.atomic():
    b_host = Host.objects.create(name='b-' + uuid.uuid4().hex[:4], address='192.0.2.33', platform=linux, is_active=False)


def new_account(asset, username, org):
    with tmp_to_org(org):
        secret = 'canary-' + uuid.uuid4().hex
        acc = Account.objects.create(asset=asset, name=username + '-' + uuid.uuid4().hex[:4], username=username,
                                     secret_type='password', secret=secret)
        return fresh(acc), secret


# ---------------------------------------------------------------- rules
with tmp_to_org(default_org):
    r_net = VaultStorageRule.objects.create(name='network devices', priority=10, connection=connections['conjur'])
    r_net.nodes.set([network])
    r_svc = VaultStorageRule.objects.create(name='service accounts', priority=20, username='svc_*',
                                            connection=connections['gcp'])
with tmp_to_org(org_b):
    VaultStorageRule.objects.create(name='OrgB default', priority=50, connection=connections['delinea'])
refresh_vault_client()
router = current()

acc_default, s_default = new_account(server, 'admin', default_org)
check('no rule matches: the configured vault (HashiCorp)', acc_default.vault_connection_id is None
      and holds(acc_default, None, s_default))
acc_net, s_net = new_account(device, 'admin', default_org)
check('asset group rule: a network device account goes to CyberArk', acc_net.vault_connection_id == connections['conjur'].id
      and holds(acc_net, connections['conjur'], s_net) and not raw(acc_net, None))
acc_svc, s_svc = new_account(server, 'svc_backup', default_org)
check('username rule: svc_* goes to Google', acc_svc.vault_connection_id == connections['gcp'].id
      and holds(acc_svc, connections['gcp'], s_svc))
acc_b, s_b = new_account(b_host, 'admin', org_b)
check('per organization: OrgB keeps its secrets in Delinea', acc_b.vault_connection_id == connections['delinea'].id
      and holds(acc_b, connections['delinea'], s_b))
check('every one of them is readable by XPAM, the database keeps only markers',
      all(fresh(a).secret == s and fresh(a)._secret == VAULT_SAVED_SECRET_MARK
          for a, s in ((acc_default, s_default), (acc_net, s_net), (acc_svc, s_svc), (acc_b, s_b))))

# ---------------------------------------------------------------- mirror
with tmp_to_org(default_org):
    r_net.mirror = connections['gcp']
    r_net.save()
refresh_vault_client()
router = current()
move_secrets_by_rules()
acc_net = fresh(acc_net)
check('mirror turned on (admin choice): the existing secret is copied to the mirror',
      acc_net.vault_mirror_id == connections['gcp'].id and holds(acc_net, connections['gcp'], s_net)
      and holds(acc_net, connections['conjur'], s_net))
acc_net2, s_net2 = new_account(device, 'oper', default_org)
check('a new secret is written to both', holds(acc_net2, connections['conjur'], s_net2)
      and holds(acc_net2, connections['gcp'], s_net2))
# the primary fails: its connection points at a wrong key
good = dict(connections['conjur'].config)
connections['conjur'].config = dict(good, VAULT_CYBERARK_API_KEY='wrong')
connections['conjur'].save()
refresh_vault_client()
router = current()
check('the primary vault fails: XPAM reads the mirror', fresh(acc_net2).secret == s_net2)
connections['conjur'].config = good
connections['conjur'].save()

# ---------------------------------------------------------------- moving
with tmp_to_org(default_org):
    r_svc.connection = connections['delinea']
    r_svc.save()
refresh_vault_client()
router = current()
move_secrets_by_rules()
acc_svc = fresh(acc_svc)
check('rule changed: the secret is moved to its new vault', acc_svc.vault_connection_id == connections['delinea'].id
      and holds(acc_svc, connections['delinea'], s_svc))
check('and removed from the old one', not raw(acc_svc, connections['gcp']))
check('still readable', fresh(acc_svc).secret == s_svc)

# ---------------------------------------------------------------- the configured vault's mirror (setting)
settings.VAULT_MIRROR = str(connections['delinea'].id)
refresh_vault_client()
router = current()
move_secrets_by_rules()
check("the configured vault's mirror (VAULT_MIRROR) gets the existing secrets",
      holds(fresh(acc_default), connections['delinea'], s_default) and holds(fresh(acc_default), None, s_default))
settings.VAULT_MIRROR = ''

# ---------------------------------------------------------------- external
existing = 'existing-' + uuid.uuid4().hex[:6]
external_value = 'from-the-customer-' + uuid.uuid4().hex[:8]
conjur = router.backend(connections['conjur'].id).client
conjur.create(existing, external_value)            # a variable the customer owns (here under XPAM's branch)
with tmp_to_org(default_org):
    ext = Account.objects.create(asset=server, name='ext-' + uuid.uuid4().hex[:4], username='dbadmin',
                                 secret_type='password', secret_source='external',
                                 secret_ref={'connection': str(connections['conjur'].id), 'path': f'xpam/{existing}'})
ext = fresh(ext)
check('external: XPAM reads the password from the existing vault', ext.secret == external_value)
check('external: XPAM keeps no copy', not ext._secret and ext.vault_connection_id is None and not raw(ext, None))
from accounts.automations.base.manager import BaseChangeSecretPushManager  # noqa: E402
qs = Account.objects.filter(id__in=[ext.id, acc_default.id], secret_reset=True).exclude(secret_source='external')
check('external: password rotation and push leave it alone', list(qs.values_list('id', flat=True)) == [acc_default.id])
conjur.update(existing, external_value + '-rotated')
check('external: a change in the customer vault is seen at the next read', fresh(ext).secret == external_value + '-rotated')

# ---------------------------------------------------------------- console lock
from rest_framework.test import APIRequestFactory, force_authenticate  # noqa: E402
from accounts.api.vault_routing import VaultConnectionViewSet  # noqa: E402
from users.models import User  # noqa: E402
admin = User.objects.get(username='admin')
factory = APIRequestFactory()
settings.VAULT_LOCKED = True
request = factory.post('/api/v1/accounts/vault-connections/', {'name': 'evil', 'type': 'hcp',
                                                              'config': {'VAULT_HCP_HOST': 'https://evil:8200'}}, format='json')
force_authenticate(request, user=admin)
response = VaultConnectionViewSet.as_view({'post': 'create'})(request)
check('locked: the console cannot add a vault', response.status_code == 400 and not VaultConnection.objects.filter(name='evil').exists(),
      response.status_code)
request = factory.delete(f'/api/v1/accounts/vault-connections/{connections["gcp"].id}/')
force_authenticate(request, user=admin)
response = VaultConnectionViewSet.as_view({'delete': 'destroy'})(request, pk=str(connections['gcp'].id))
check('locked: the console cannot remove a managed vault', response.status_code == 403, response.status_code)
request = factory.get('/api/v1/accounts/vault-connections/')
force_authenticate(request, user=admin)
response = VaultConnectionViewSet.as_view({'get': 'list'})(request)
shown = json.dumps(response.data)
secrets_shown = [v for c in connections.values() for k, v in c.config.items()
                 if any(h in k for h in ('PASSWORD', 'API_KEY', 'CREDENTIALS', 'TOKEN', 'KEY_PEM')) and v and str(v) in shown]
check('the console sees the vaults but never their keys or passwords', response.status_code == 200 and not secrets_shown)

print(f'RESULT: {sum(results)}/{len(results)} passed', flush=True)
sys.exit(0 if all(results) else 1)
