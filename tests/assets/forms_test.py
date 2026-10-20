import os, sys
sys.path.insert(0, '/opt/jumpserver/apps'); os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'jumpserver.settings')
import django; django.setup()
from django.conf import settings
settings.ALLOWED_HOSTS = list(settings.ALLOWED_HOSTS) + ['testserver']
from rest_framework.test import APIClient
from orgs.models import Organization
from orgs.utils import set_current_org
from assets.models import Platform, Node, Asset
from users.models import User
results = []
def check(name, ok, detail=''):
    results.append(bool(ok)); print(('PASS ' if ok else 'FAIL ') + name + (f'  [{str(detail)[:260]}]' if detail != '' else ''), flush=True)
org = Organization.default(); set_current_org(org)
A = APIClient(); A.force_authenticate(User.objects.get(username='admin'))
H = {'HTTP_X_JMS_ORG': str(org.id)}
root = Node.org_root()
def post(path, data):
    r = A.post(path, data, format='json', **H); set_current_org(org); return r
def drop(a):
    A.delete(f'/api/v1/assets/assets/{a}/', **H); set_current_org(org)

# web asset: bare address, empty selectors
r = post('/api/v1/assets/webs/', {'name': 'ux-web', 'address': 'portal.example.com', 'platform': Platform.objects.get(name='Website').id,
                                   'nodes': [str(root.id)], 'protocols': [{'name': 'http', 'port': 80}]})
check('web asset with a bare address is created', r.status_code == 201, r.data)
if r.status_code == 201:
    w = Asset.objects.get(id=r.data['id'])
    check('the address gets https://', w.address == 'https://portal.example.com', w.address)
    check('the port follows the address (443)', w.protocols.get(name='http').port == 443, w.protocols.get(name='http').port)
    check('sign-in selectors are empty (found automatically)', r.data.get('username_selector') == '' and
          r.data.get('submit_selector') == '' and r.data.get('password_selector') == '', r.data.get('submit_selector'))
    drop(w.id)
r = post('/api/v1/assets/webs/', {'name': 'ux-web2', 'address': 'http://intranet:8080/app', 'platform': Platform.objects.get(name='Website').id,
                                   'nodes': [str(root.id)], 'protocols': [{'name': 'http', 'port': 80}]})
if r.status_code == 201:
    w = Asset.objects.get(id=r.data['id'])
    check('an explicit http address and port are kept', w.address == 'http://intranet:8080/app' and w.protocols.get(name='http').port == 8080,
          (w.address, w.protocols.get(name='http').port))
    drop(w.id)
else:
    check('web asset with an explicit http address', False, r.data)
opts = A.options('/api/v1/assets/webs/', **H).data
help_text = str(opts.get('actions', {}).get('POST', {}).get('success_selector', {}).get('help_text', ''))
check('the success selector is described as optional', 'Optional' in help_text and 'Required' not in help_text, help_text)

# JIT readiness: a FortiGate without a privileged account, then with one
r = post('/api/v1/assets/devices/', {'name': 'ux-fw', 'address': '192.0.2.1', 'platform': Platform.objects.get(name='FortiGate').id,
                                      'nodes': [str(root.id)], 'protocols': [{'name': 'ssh', 'port': 22}],
                                      'accounts': [{'name': 'admin', 'username': 'admin', 'secret_type': 'password', 'secret': 'x-Pass_1', 'privileged': False}]})
assert r.status_code == 201, r.data
fw = r.data['id']
rd = post('/api/v1/accounts/jit-policies/readiness/', {'assets': {'type': 'ids', 'ids': [fw]}}).data
check('readiness: the device is not ready and the reason says what to fix',
      rd['total'] == 1 and rd['ready'] == 0 and 'privileged' in rd['problems'][0]['reason'].lower() and rd['problems'][0]['assets'][0]['name'] == 'ux-fw', rd)
from accounts.models import Account
Account.objects.filter(asset_id=fw).update(privileged=True)
rd = post('/api/v1/accounts/jit-policies/readiness/', {'assets': {'type': 'all'}}).data
check('readiness: ready once the admin account is privileged (all assets)', rd['total'] == 1 and rd['ready'] == 1 and not rd['problems'], rd)
rd = post('/api/v1/accounts/jit-policies/readiness/', {'assets': {}}).data
check('readiness: nothing chosen', rd['total'] == 0, rd)
drop(fw)
print(f'RESULT: {sum(results)}/{len(results)} passed')
