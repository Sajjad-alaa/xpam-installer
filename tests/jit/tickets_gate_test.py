"""Isolated stack: just-in-time access needs Tickets enabled and licensed — without it no just-in-time account is
offered, the JIT APIs refuse, and a "JIT only" rule still hides the standing accounts (zero standing privilege fails
closed); a failed licence check keeps the last answer instead of switching JIT off.
  run with tests/jit/access_run.sh (TEST=tickets_gate_test.py)"""
import os, sys, traceback
sys.path.insert(0, '/opt/jumpserver/apps'); os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'jumpserver.settings')
import django; django.setup()
from django.conf import settings
from django.utils import timezone
settings.ALLOWED_HOSTS = list(settings.ALLOWED_HOSTS) + ['testserver']
import xpack.utils
LICENCE = {'ticket': True, 'fail': False}


def _licence():
    if LICENCE['fail']:
        raise RuntimeError('database restarting')
    return LICENCE['ticket']


xpack.utils.has_ticket_license = _licence
from rest_framework.test import APIClient
from orgs.models import Organization
from orgs.utils import set_current_org, tmp_to_root_org
from assets.models import Platform, Node, Asset
from accounts.models import JITPolicy
from accounts.jit.policy import select_policy, tickets_enabled
from perms.models import AssetPermission
from perms.utils import PermAssetDetailUtil
from users.models import User

ROOT_PW = os.environ['ROOT_PASSWORD']
results = []


def check(name, ok, detail=''):
    results.append(bool(ok))
    print(('PASS ' if ok else 'FAIL ') + name + (f'  [{str(detail)[:240]}]' if detail != '' else ''), flush=True)


org = Organization.default(); set_current_org(org)
H = {'HTTP_X_JMS_ORG': str(org.id)}
admin = User.objects.get(username='admin')
user = User.objects.filter(username='tg.user').first() or User.objects.create(
    username='tg.user', name='Gate User', email='tg.user@example.invalid', is_first_login=False)
org.add_member(user)
A = APIClient(); A.force_authenticate(admin)
U = APIClient(); U.force_authenticate(user)


def offered(host):
    util = PermAssetDetailUtil(user, host)
    return sorted(a.username for a in util.get_permed_accounts_from_perms(util.user_asset_perms, user, host))


def api(client, url):
    r = client.get(url, **H)
    set_current_org(org)
    return r.status_code


def cleanup():
    with tmp_to_root_org():
        AssetPermission.objects.filter(name__startswith='tg-').delete()
        JITPolicy.objects.filter(name__startswith='tg-').delete()
        for a in Asset.objects.filter(name__startswith='tg-'):
            A.delete(f'/api/v1/assets/assets/{a.id}/', **H)
    set_current_org(org)


cleanup()
try:
    r = A.post('/api/v1/assets/hosts/', {
        'name': 'tg-linux', 'address': 'flowhost', 'platform': Platform.objects.get(name='Linux').id,
        'nodes': [str(Node.org_root().id)], 'protocols': [{'name': 'ssh', 'port': 22}],
        'accounts': [{'name': 'root', 'username': 'root', 'secret_type': 'password', 'secret': ROOT_PW, 'privileged': True},
                     {'name': 'svc', 'username': 'svc', 'secret_type': 'password', 'secret': ROOT_PW}]},
        format='json', **H)
    set_current_org(org)
    host = Asset.objects.get(id=r.data['id'])
    r = A.post('/api/v1/accounts/jit-policies/', {
        'name': 'tg-zsp', 'scope': 'all', 'priority': 5, 'jit_only': True, 'mode': 'per_session',
        'users': {'type': 'ids', 'ids': [str(user.id)]}, 'assets': {'type': 'ids', 'ids': [str(host.id)]}},
        format='json', **H)
    set_current_org(org)
    check('a "JIT only" rule for the user on the server', r.status_code == 201, r.data)
    perm = AssetPermission.objects.create(name='tg-standing', accounts=['@ALL'], actions=4095,
                                          date_expired=timezone.now() + timezone.timedelta(days=1))
    perm.users.add(user); perm.assets.add(host)

    check('Tickets on: only the just-in-time account is offered', offered(host) == ['@JIT'], offered(host))
    check('... and the rule gives one at connect', select_policy(user, host)[0] is not None)

    settings.TICKETS_ENABLED = False
    check('Tickets off: no just-in-time account, and the standing accounts stay hidden', offered(host) == [], offered(host))
    check('... none given at connect', select_policy(user, host) == (None, None))
    check('... the JIT APIs refuse', api(A, '/api/v1/accounts/jit-policies/') == 403 and api(U, '/api/v1/accounts/jit-access/') == 403)
    settings.TICKETS_ENABLED = True

    LICENCE['ticket'] = False
    check('no Tickets licence: the same (nothing offered, standing accounts hidden)',
          not tickets_enabled() and offered(host) == [], offered(host))
    LICENCE['ticket'] = True
    check('licence back: the just-in-time account again', tickets_enabled() and offered(host) == ['@JIT'], offered(host))

    LICENCE['fail'] = True
    check('a failed licence check keeps the last answer (JIT stays on)', tickets_enabled() and offered(host) == ['@JIT'])
    LICENCE['fail'] = False
except Exception:
    traceback.print_exc()
    check('no error', False)
finally:
    settings.TICKETS_ENABLED = True
    LICENCE.update(ticket=True, fail=False)
    cleanup()

print(f'RESULT: {sum(results)}/{len(results)} passed')
sys.exit(0 if all(results) else 1)
