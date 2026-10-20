import os, sys
sys.path.insert(0, '/opt/jumpserver/apps'); os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'jumpserver.settings')
import django; django.setup()
from django.conf import settings
settings.ALLOWED_HOSTS = list(settings.ALLOWED_HOSTS) + ['testserver']
from rest_framework.test import APIClient
from orgs.models import Organization
from orgs.utils import set_current_org
from assets.models import Platform, Asset
from accounts.models import Account
from users.models import User
EP = os.environ['EMU_PASSWORD']
results = []
def check(name, ok, detail=''):
    results.append(bool(ok)); print(('PASS ' if ok else 'FAIL ') + name + (f'  [{str(detail)[:240]}]' if detail != '' else ''), flush=True)
org = Organization.default(); set_current_org(org)
A = APIClient(); A.force_authenticate(User.objects.get(username='admin'))
H = {'HTTP_X_JMS_ORG': str(org.id)}
def post(p, d):
    r = A.post(p, d, format='json', **H); set_current_org(org); return r
def get(p):
    r = A.get(p, **H); set_current_org(org); return r
general = Platform.objects.get(name='Huawei', category='device').id

r = post('/api/v1/assets/tools/bulk-add/', {'platform': general, 'lines': 'sw-1 10.0.0.1\nsw-2 10.0.0.2', 'nodes': []})
check('bulk add refuses more assets than the licence allows', r.status_code == 400 and 'licence' in r.data['detail'].lower(), r.data)
r = post('/api/v1/assets/tools/bulk-add/', {'platform': general, 'lines': '# devices\ncore-sw netemu', 'nodes': [],
                                             'account': {'username': 'admin', 'secret': EP, 'privileged': True}})
ok = r.status_code == 200 and len(r.data['created']) == 1 and not r.data['failed']
check('bulk add creates the asset with its account', ok, r.data)
aid = r.data['created'][0]['id'] if ok else None
a = Asset.objects.get(id=aid)
check('the account is privileged and the default protocol is there',
      Account.objects.filter(asset=a, username='admin', privileged=True).exists() and a.protocols.filter(name='ssh').exists())
r = post('/api/v1/assets/tools/bulk-add/', {'platform': general, 'lines': '', 'nodes': []})
check('an empty list is refused with a message', r.status_code == 400 and r.data['detail'], r.data)

# detection: the emulator's Cisco IOS answers on 2203, FortiGate on 2201
for port, expect in ((2203, 'Cisco'), (2201, 'FortiGate')):
    a.protocols.filter(name='ssh').update(port=port)
    r = post('/api/v1/assets/tools/detect-platform/', {'assets': [aid]})
    item = r.data[0] if r.status_code == 200 else r.data
    a = Asset.objects.get(id=aid)
    check(f'detect: the device on port {port} is recognised as {expect} and moved to it',
          r.status_code == 200 and item['after'] == expect and a.platform.name == expect, item)
check('detect: moving to FortiGate adds its web admin protocol', a.protocols.filter(name='http', port=443).exists(),
      list(a.protocols.values_list('name', 'port')))
Account.objects.filter(asset=a).update(privileged=False)
r = post('/api/v1/assets/tools/detect-platform/', {'assets': [aid]})
check('detect: without a privileged account it says what to add', r.data[0]['error'] and 'privileged' in r.data[0]['error'].lower(), r.data)

# attention
Asset.objects.filter(id=aid).update(connectivity='err')
r = get('/api/v1/assets/tools/attention/')
keys = {g['key']: g for g in r.data['groups']}
check('attention: unreachable asset listed', 'unreachable' in keys and keys['unreachable']['assets'][0]['name'] == 'core-sw', r.data)
check('attention: missing privileged account listed with the fix', 'no_privileged' in keys and 'Privileged' in keys['no_privileged']['fix'])
Account.objects.filter(asset=a).update(privileged=True, connectivity='err')
r = get('/api/v1/assets/tools/attention/')
keys = {g['key'] for g in r.data['groups']}
check('attention: failed account check listed; privileged problem gone', 'account_failed' in keys and 'no_privileged' not in keys, keys)
A.delete(f'/api/v1/assets/assets/{aid}/', **H); set_current_org(org)

# detection in another organization (the work must happen in the request's organization)
from orgs.utils import tmp_to_org
other = Organization.objects.create(name='tools-second')
with tmp_to_org(other):
    from assets.models import Node
    oroot = Node.org_root()
H2 = {'HTTP_X_JMS_ORG': str(other.id)}
r = A.post('/api/v1/assets/devices/', {'name': 'org2-sw', 'address': 'netemu', 'platform': general, 'nodes': [str(oroot.id)],
            'protocols': [{'name': 'ssh', 'port': 2203}],
            'accounts': [{'name': 'admin', 'username': 'admin', 'secret_type': 'password', 'secret': EP, 'privileged': True}]},
           format='json', **H2)
set_current_org(org)
check('a device is created in a second organization', r.status_code == 201, r.data)
oid = r.data.get('id')
r = A.post('/api/v1/assets/tools/detect-platform/', {'assets': [oid, 'not-a-uuid']}, format='json', **H2)
set_current_org(org)
check('detect works in a second organization (and ignores a malformed id)',
      r.status_code == 200 and r.data[0]['after'] == 'Cisco' and r.data[0]['changed'], r.data)
r = A.get('/api/v1/assets/tools/attention/', **H2); set_current_org(org)
check('attention is scoped to that organization', r.status_code == 200 and r.data['total'] == 1, r.data)
A.delete(f'/api/v1/assets/assets/{oid}/', **H2); set_current_org(org)
r = post('/api/v1/assets/tools/detect-platform/', {'assets': ['x']})
check('detect with only malformed ids gives a message, not an error', r.status_code == 400, r.data)
print(f'RESULT: {sum(results)}/{len(results)} passed')
