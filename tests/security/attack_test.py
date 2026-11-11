# Attack suite (run in `manage.py shell` on a throwaway database; tests/security/attack_run.sh): tries to break the
# security-critical flows and prints "PASS <name>" / "FAIL <name> <detail>"; every attack has a control showing the
# legitimate path still works.
#   signed requests     an old or future Date (replay) is refused
#   MFA                 password alone gives no token; another user's MFA mark does not count; OTP guessing blocks
#   login               password guessing blocks the account
#   CSRF                a cookie-authenticated write without the CSRF token is refused
#   tokens              a disabled user's bearer token stops working
#   connection token    another user cannot read or use it; users cannot call the component secret API
#   tickets             the applicant cannot approve their own request; a non-assignee cannot (single or bulk)
#   face                only the face engine's service account may report a face result
#   secrets             an ordinary user cannot read account secrets
#   licence             bulk creating users cannot pass the licence's user limit
#   redirects           the login "next" URL cannot point to another site
#   media               path traversal through /media/ is refused
import base64
import hashlib
import hmac
import json
import secrets as pysecrets
import time
from email.utils import formatdate

import pyotp
from django.db import IntegrityError, transaction
from django.test import Client
from django.utils import timezone

import xpack.utils as xu
xu.has_ticket_license = lambda *a, **k: True
xu.get_license_user_limit = lambda *a, **k: 100000
for _n in ('get_license_asset_limit', 'get_license_asset_count'):
    if hasattr(xu, _n):
        setattr(xu, _n, lambda *a, **k: 100000)
import importlib; _asset_api = importlib.import_module('assets.api.asset.asset')
_asset_api.get_license_asset_limit = lambda *a, **k: 100000

from accounts.models import Account
from assets.models import Node, Platform
from authentication.models import AccessKey, ConnectionToken
from orgs.models import Organization
from orgs.utils import tmp_to_org
from perms.models import AssetPermission
from rbac.builtin import BuiltinRole
from rbac.models import RoleBinding
from terminal.models import Terminal
from users.models import User

R = pysecrets.token_hex(3)
J = 'application/json'
PW = 'Attack-Only-Pass-2026!'
results = []


def check(name, ok, detail=''):
    ok = bool(ok)
    results.append(ok)
    print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else ' ' + str(detail)[:300]), flush=True)


# (the throwaway database's migration stops before Django creates every model permission: create them, then fill the
# built-in roles, so ordinary users can do what they can in a real installation)
from django.apps import apps as _apps
from django.contrib.auth.management import create_permissions as _cp
for _app in _apps.get_app_configs():
    _cp(_app, verbosity=0)
BuiltinRole.sync_to_db()
org = Organization.default()
admin = User.objects.get(username='admin')
admin.set_password(PW); admin.is_first_login = False; admin.need_update_password = False; admin.save()


def mk_user(name, role=BuiltinRole.org_user, otp=False):
    u = User.objects.create(username=name, name=name, email=f'{name}@example.com', is_first_login=False)
    u.set_password(PW); u.need_update_password = False
    if otp:
        u.otp_secret_key = pyotp.random_base32(); u.mfa_level = 1
    u.save()
    u.system_roles.add_role_system_user()
    try:  # (a new user may already have the default organization's user role)
        with transaction.atomic():
            RoleBinding.objects_raw.create(user=u, role=role.get_role(), org=org, scope='org')
    except IntegrityError:
        pass
    return u


def client(user=None, csrf=False):
    c = Client(HTTP_HOST='localhost', enforce_csrf_checks=csrf, raise_request_exception=False)
    if user:
        c.force_login(user)
    return c


def req(c, method, path, data=None, **extra):
    extra.setdefault('HTTP_X_JMS_ORG', str(org.id))
    fn = getattr(c, method.lower())
    r = fn(path, **extra) if data is None else fn(path, data=json.dumps(data), content_type=J, **extra)
    return r.status_code, r.content.decode('utf-8', 'ignore')


plain_a = mk_user(f'plaina{R}')
plain_b = mk_user(f'plainb{R}')
mfa_user = mk_user(f'mfauser{R}', otp=True)
mfa_attacker = mk_user(f'mfaatk{R}', otp=True)
locked = mk_user(f'locked{R}')
ADMIN = client(admin)

# ------------------------------------------------------------------ signed requests (HTTP Signature)
key = AccessKey.objects.create(user=admin)


def signed_get(path, when):
    date = formatdate(when, usegmt=True)
    text = '(request-target): get %s\ndate: %s' % (path, date)
    sig = base64.b64encode(hmac.new(str(key.secret).encode(), text.encode(), hashlib.sha256).digest()).decode()
    auth = 'Signature keyId="%s",algorithm="hmac-sha256",headers="(request-target) date",signature="%s"' % (key.id, sig)
    r = Client(HTTP_HOST='localhost').get(path, HTTP_DATE=date, HTTP_AUTHORIZATION=auth, HTTP_X_JMS_ORG='ROOT')
    return r.status_code


now = time.time()
check('signature: a fresh signed request works (control)', signed_get('/api/v1/users/profile/', now) == 200)
check('signature: a request signed 2 days ago is refused (replay)', signed_get('/api/v1/users/profile/', now - 2 * 86400) == 401,
      signed_get('/api/v1/users/profile/', now - 2 * 86400))
check('signature: a request dated 2 days ahead is refused', signed_get('/api/v1/users/profile/', now + 2 * 86400) == 401,
      signed_get('/api/v1/users/profile/', now + 2 * 86400))
check('signature: 2 minutes of clock difference is tolerated (control)', signed_get('/api/v1/users/profile/', now - 120) == 200)
# KoKo and the web connector sign with China local time labelled 'CST' (signed_get_raw: the Date as they send it)
def signed_get_raw(path, date):
    text = '(request-target): get %s\ndate: %s' % (path, date)
    sig = base64.b64encode(hmac.new(str(key.secret).encode(), text.encode(), hashlib.sha256).digest()).decode()
    auth = 'Signature keyId="%s",algorithm="hmac-sha256",headers="(request-target) date",signature="%s"' % (key.id, sig)
    return Client(HTTP_HOST='localhost').get(path, HTTP_DATE=date, HTTP_AUTHORIZATION=auth, HTTP_X_JMS_ORG='ROOT').status_code
china = time.strftime('%a, %d %b %Y %H:%M:%S CST', time.gmtime(now + 8 * 3600))
check("signature: a component's China-local 'CST' date works (control)", signed_get_raw('/api/v1/users/profile/', china) == 200,
      signed_get_raw('/api/v1/users/profile/', china))

# ------------------------------------------------------------------ MFA
anon = client()
st, body = req(anon, 'POST', '/api/v1/authentication/auth/', {'username': mfa_user.username, 'password': PW})
check('MFA: password alone gives no token to a user with MFA', 'token' not in json.loads(body or '{}'), (st, body[:200]))

# the attacker passes MFA for their own account, then tries the victim's password in the same session
s = client()
req(s, 'POST', '/api/v1/authentication/auth/', {'username': mfa_attacker.username, 'password': PW})
code = pyotp.TOTP(mfa_attacker.otp_secret_key).now()
st, body = req(s, 'POST', '/api/v1/authentication/mfa/verify/', {'type': 'otp', 'code': code})
st2, body2 = req(s, 'POST', '/api/v1/authentication/auth/', {'username': mfa_attacker.username, 'password': PW})
check('MFA: the attacker gets their own token after their MFA (control)', 'token' in json.loads(body2 or '{}'), (st, body[:120], st2, body2[:160]))
st, body = req(s, 'POST', '/api/v1/authentication/auth/', {'username': mfa_user.username, 'password': PW})
check("MFA: another user's MFA mark in the session does not unlock the victim", 'token' not in json.loads(body or '{}'), (st, body[:200]))

g = client()
req(g, 'POST', '/api/v1/authentication/auth/', {'username': mfa_user.username, 'password': PW})
for _ in range(12):
    req(g, 'POST', '/api/v1/authentication/mfa/verify/', {'type': 'otp', 'code': '000000'})
good = pyotp.TOTP(mfa_user.otp_secret_key).now()
st, body = req(g, 'POST', '/api/v1/authentication/mfa/verify/', {'type': 'otp', 'code': good})
st3, body3 = req(g, 'POST', '/api/v1/authentication/auth/', {'username': mfa_user.username, 'password': PW})
check('MFA: after 12 wrong OTP codes even the right one is refused (blocked)', 'token' not in json.loads(body3 or '{}'),
      (st, body[:150], st3, body3[:150]))

# ------------------------------------------------------------------ login brute force
b = client()
for _ in range(9):
    req(b, 'POST', '/api/v1/authentication/auth/', {'username': locked.username, 'password': 'wrong-' + R})
st, body = req(client(), 'POST', '/api/v1/authentication/auth/', {'username': locked.username, 'password': PW})
check('login: after 9 wrong passwords the right one is refused (blocked)', 'token' not in json.loads(body or '{}'), (st, body[:200]))
st, body = req(client(), 'POST', '/api/v1/authentication/auth/', {'username': plain_b.username, 'password': PW})
check('login: another user from the same address can still log in (control)', 'token' in json.loads(body or '{}'), (st, body[:200]))

# ------------------------------------------------------------------ CSRF
c = client(plain_a, csrf=True)
st, body = req(c, 'PATCH', '/api/v1/users/profile/', {'name': 'csrf-' + R})
plain_a.refresh_from_db()
check('CSRF: a cookie-authenticated write without the CSRF token is refused', plain_a.name != 'csrf-' + R, (st, body[:150]))

# ------------------------------------------------------------------ bearer token of a disabled user
st, body = req(client(), 'POST', '/api/v1/authentication/auth/', {'username': plain_b.username, 'password': PW})
tok = json.loads(body).get('token', '')
st1, _ = req(client(), 'GET', '/api/v1/users/profile/', HTTP_AUTHORIZATION='Bearer ' + tok)
User.objects.filter(id=plain_b.id).update(is_active=False)
st2, _ = req(client(), 'GET', '/api/v1/users/profile/', HTTP_AUTHORIZATION='Bearer ' + tok)
check('token: works while the user is active (control)', st1 == 200, st1)
check('token: a disabled user\'s token stops working', st2 in (401, 403), st2)
User.objects.filter(id=plain_b.id).update(is_active=True)

# ------------------------------------------------------------------ assets, permission, accounts
with tmp_to_org(org):
    node = Node.org_root()
linux = Platform.objects.filter(name='Linux').first()
st, body = req(ADMIN, 'POST', '/api/v1/assets/hosts/', {
    'name': f'atk-host-{R}', 'address': '10.77.0.1', 'platform': linux.id, 'nodes': [str(node.id)],
    'protocols': [{'name': 'ssh', 'port': 22}]})
host_id = json.loads(body)['id']
st, body = req(ADMIN, 'POST', '/api/v1/accounts/accounts/', {
    'asset': host_id, 'name': 'root', 'username': 'root', 'secret_type': 'password', 'secret': 'canary-secret-' + R,
    'privileged': True})
assert st == 201, (st, body[:200])
with tmp_to_org(org):
    acc = Account.objects.get(id=json.loads(body)['id'])
    perm = AssetPermission.objects.create(name=f'atk-perm-{R}', accounts=['@ALL'], actions=0xFFFF, protocols=['all'])
    perm.users.add(plain_a); perm.assets.add(host_id)

A = client(plain_a)
B = client(plain_b)

# account secrets
st, body = req(A, 'GET', f'/api/v1/accounts/account-secrets/{acc.id}/')
check('secrets: an ordinary user cannot read an account secret', 'canary-secret-' not in body, (st, body[:150]))
st, body = req(A, 'GET', f'/api/v1/accounts/accounts/{acc.id}/')
check('secrets: the account detail shows no secret to an ordinary user', 'canary-secret-' not in body, (st, body[:150]))

# connection token
st, body = req(A, 'POST', '/api/v1/authentication/connection-token/', {
    # (a real account's alias is its id)
    'asset': host_id, 'account': str(acc.id), 'protocol': 'ssh', 'connect_method': 'web_cli', 'connect_options': {}})
ct = json.loads(body) if st in (200, 201) else {}
check('connection token: the permitted user gets one (control)', ct.get('id'), (st, body[:200]))
if ct.get('id'):
    st, body = req(B, 'GET', f"/api/v1/authentication/connection-token/{ct['id']}/")
    check("connection token: another user cannot read it", st in (403, 404) and 'canary-secret-' not in body, (st, body[:150]))
    st, body = req(A, 'POST', '/api/v1/authentication/super-connection-token/secret/', {'id': ct['id']})
    check('connection token: a user cannot call the component secret API', st in (401, 403, 404) and 'canary-secret-' not in body,
          (st, body[:150]))
    st, body = req(B, 'POST', '/api/v1/authentication/super-connection-token/secret/', {'id': ct['id']})
    check("connection token: another user cannot get the secret either", st in (401, 403, 404) and 'canary-secret-' not in body,
          (st, body[:150]))
    ConnectionToken.objects.filter(id=ct['id']).update(date_expired=timezone.now() - timezone.timedelta(minutes=1))
    svc, _k = User.create_service_account(f'koko-{R}', f'koko-{R}{User.service_account_email_suffix}', '')
    svc.system_roles.add_role_system_component()
    Terminal.objects.create(name=f'koko-{R}', type='koko', user=svc)
    st, body = req(client(svc), 'POST', '/api/v1/authentication/super-connection-token/secret/', {'id': ct['id']})
    check('connection token: an expired token gives no secret, even to a component', 'canary-secret-' not in body, (st, body[:150]))

# face result: only the face engine
st, body = req(A, 'POST', '/api/v1/authentication/face/callback/', {'token': 'x' * 32, 'success': True, 'face_code': 'AAAA'})
check('face: an ordinary user cannot report a face result', st in (401, 403), (st, body[:150]))

# ------------------------------------------------------------------ tickets
from tickets.models import TicketFlow
flow = TicketFlow.objects.filter(type='apply_asset').first()
st, body = req(A, 'POST', '/api/v1/tickets/apply-asset-tickets/open/', {
    'title': f'atk-{R}', 'org_id': str(org.id), 'flow_id': str(flow.id) if flow else None, 'apply_assets': [host_id], 'apply_accounts': ['@ALL'],
    'apply_actions': ['connect'], 'apply_date_start': timezone.now().isoformat(),
    'apply_date_expired': (timezone.now() + timezone.timedelta(hours=2)).isoformat()})
tk = json.loads(body) if st in (200, 201) else {}
check('tickets: a user can open an access request (control)', tk.get('id'), (st, body[:200]))
if tk.get('id'):
    st, body = req(A, 'PUT', f"/api/v1/tickets/apply-asset-tickets/{tk['id']}/approve/", {})
    from tickets.models import ApplyAssetTicket
    t = ApplyAssetTicket.objects.get(id=tk['id'])
    check('tickets: the applicant cannot approve their own request', t.state != 'approved', (st, body[:150], t.state))
    st, body = req(B, 'PUT', f"/api/v1/tickets/apply-asset-tickets/{tk['id']}/approve/", {})
    t.refresh_from_db()
    check('tickets: a user who is not an assignee cannot approve', t.state != 'approved', (st, body[:150], t.state))
    st, body = req(B, 'PUT', '/api/v1/tickets/tickets/bulk/?action=approve', {'tickets': [tk['id']]})
    t.refresh_from_db()
    check('tickets: nor through bulk approve', t.state != 'approved', (st, body[:150], t.state))

# ------------------------------------------------------------------ licence user limit
current = User.objects.filter(is_service_account=False).count()
xu.get_license_user_limit = lambda *a, **k: current
st, body = req(ADMIN, 'POST', '/api/v1/users/users/', [
    {'username': f'bulk1{R}', 'name': 'b1', 'email': f'bulk1{R}@example.com', 'password_strategy': 'custom', 'password': PW},
    {'username': f'bulk2{R}', 'name': 'b2', 'email': f'bulk2{R}@example.com', 'password_strategy': 'custom', 'password': PW}])
after = User.objects.filter(is_service_account=False).count()
check('licence: bulk creating users cannot pass the user limit', after <= current, (st, body[:200], current, after))
xu.get_license_user_limit = lambda *a, **k: 100000

# ------------------------------------------------------------------ redirects after login
from common.utils import safe_next_url
from django.test import RequestFactory
rq = RequestFactory().get('/', HTTP_HOST='localhost')
for bad in ('https://evil.example/x', '//evil.example', '/\\evil.example', '\\\\evil.example', 'javascript:alert(1)',
            'https:evil.example', '/%2F%2Fevil.example', ' //evil.example'):
    out = safe_next_url(bad, request=rq)
    o = str(out or '')  # (a path on this site; percent-encoded slashes are not decoded into another host by browsers)
    check(f'redirect: next={bad!r} is not followed off-site',
          not o or (o.startswith('/') and not o.startswith(('//', '/\\')) and ':' not in o.split('/')[1][:12]), out)
check('redirect: a local next URL is kept (control)', safe_next_url('/ui/#/console', request=rq) == '/ui/#/console',
      safe_next_url('/ui/#/console', request=rq))

# ------------------------------------------------------------------ media path traversal
for p in ('/media/../xpam/settings/base.py', '/media/../jumpserver/settings/base.py', '/media/%2e%2e/%2e%2e/etc/passwd', '/media/..%2f..%2fetc%2fpasswd',
          '/media/xpack/../../config.yml'):
    st, body = req(A, 'GET', p)
    check(f'media: {p} is refused', st in (400, 403, 404) and 'root:' not in body and 'SECRET_KEY' not in body, (st, body[:100]))

print(f'DONE {sum(results)}/{len(results)} passed', flush=True)
