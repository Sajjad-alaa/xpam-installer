# Every API URL of core, every method, as several identities, against planted canaries (run in `manage.py shell`
# on a throwaway database; tests/security/api_matrix_run.sh). Findings: one JSON object per line ("FINDING {...}").
#   identities: anonymous, plainA (a user of org A, permitted to asset A1 only), orgadminA (admin of org A),
#   auditorA (auditor of org A), svc (an SSH/RDP service account), admin (system admin, the reference)
#   org header: the identity's own org, org B, ROOT
#   a finding: a canary (another org's object id, a secret, another org's user's email) in a 2xx answer to someone
#   who must not see it; a 2xx to a write that must be refused; an escalation that worked.
import json
import re
import secrets as pysecrets
import signal
import time
import uuid

from django.apps import apps
from django.test import Client
from django.urls import get_resolver
from django.urls.resolvers import URLPattern, URLResolver

import xpack.utils as xu
xu.get_license_user_limit = lambda *a, **k: 1000
for _name in ('get_license_asset_limit', 'get_license_asset_count'):
    if hasattr(xu, _name):
        setattr(xu, _name, lambda *a, **k: 100000)
xu.has_ticket_license = lambda *a, **k: True
import importlib; _asset_api = importlib.import_module('assets.api.asset.asset')
_asset_api.get_license_asset_limit = lambda *a, **k: 100000

from accounts.models import Account
from assets.models import Host, Node, Platform
from orgs.models import Organization
from orgs.utils import tmp_to_org, tmp_to_root_org
from perms.models import AssetPermission
from rbac.builtin import BuiltinRole
from rbac.models import RoleBinding
from terminal.models import Terminal
from users.models import User

R = pysecrets.token_hex(4)
CANARY = {
    'secret_B': f'CANARY-SECRET-B-{R}',
    'secret_A2': f'CANARY-SECRET-A2-{R}',
    'secret_A1': f'CANARY-SECRET-A1-{R}',
    'email_B': f'canary-b-{R}@example.com',
    'username_B': f'cbuser{R}',
}
J = 'application/json'


def finding(kind, who, org, method, path, status, detail=''):
    print('FINDING ' + json.dumps({'kind': kind, 'who': who, 'org': str(org), 'method': method, 'path': path,
                                   'status': status, 'detail': str(detail)[:300]}), flush=True)


# ------------------------------------------------------------------ the world
# (the built-in roles' permissions: migrate stops at a missing data file in this throwaway database before it fills
# them in; without this the User and Auditor roles grant nothing and the low identities are under-tested)
BuiltinRole.sync_to_db()
org_a = Organization.objects.create(name=f'org-a-{R}')
org_b = Organization.objects.create(name=f'org-b-{R}')
admin = User.objects.get(username='admin')
User.objects.filter(username='admin').update(is_first_login=False)


def mk_user(name, email=None):
    u = User.objects.create(username=name, name=name, email=email or f'{name}@example.com', is_first_login=False)
    u.set_password(pysecrets.token_urlsafe(16)); u.save()
    u.system_roles.add_role_system_user()  # (as every user created through the API)
    return u


plain_a = mk_user(f'plaina-{R}')
plain_b = mk_user(f'plainb-{R}', CANARY['email_B'])
orgadmin_a = mk_user(f'orgadmina-{R}')
auditor_a = mk_user(f'auditora-{R}')
for u, org, role in ((plain_a, org_a, BuiltinRole.org_user), (plain_b, org_b, BuiltinRole.org_user),
                     (orgadmin_a, org_a, BuiltinRole.org_admin), (auditor_a, org_a, BuiltinRole.org_auditor)):
    RoleBinding.objects.create(user=u, role=role.get_role(), org=org, scope='org')

svc, _ = User.create_service_account(f'svc-{R}', f'svc-{R}{User.service_account_email_suffix}', '')
svc.system_roles.add_role_system_component()
Terminal.objects.create(name=f'svc-{R}', type='koko', user=svc)

linux = Platform.objects.filter(name='Linux').first()
objs = {}
_admin_client = Client(HTTP_HOST='localhost', raise_request_exception=True)
_admin_client.force_login(admin)
for org, names in ((org_a, ('A1', 'A2')), (org_b, ('B1',))):
    with tmp_to_org(org):
        node = Node.org_root()
    for n in names:
        # (through the API, as the system admin: the asset signals need a real request)
        secret = CANARY['secret_' + ('B' if n == 'B1' else n)]
        r = _admin_client.post('/api/v1/assets/hosts/', data=json.dumps({
            'name': f'host-{n}-{R}', 'address': f'10.9.9.{len(objs) + 1}', 'platform': linux.id,
            'nodes': [str(node.id)], 'protocols': [{'name': 'ssh', 'port': 22}]}), content_type=J,
            HTTP_X_JMS_ORG=str(org.id))
        assert r.status_code == 201, (r.status_code, r.content[:300])
        hid = r.json()['id']
        r = _admin_client.post('/api/v1/accounts/accounts/', data=json.dumps({
            'asset': hid, 'name': f'root-{n}', 'username': CANARY['username_B'] if n == 'B1' else 'root',
            'secret_type': 'password', 'secret': secret,
            'privileged': True}), content_type=J, HTTP_X_JMS_ORG=str(org.id))
        assert r.status_code == 201, (r.status_code, r.content[:300])
        with tmp_to_org(org):
            objs[n] = (Host.objects.get(id=hid), Account.objects.get(id=r.json()['id']))
with tmp_to_org(org_a):
    perm = AssetPermission.objects.create(name=f'perm-a-{R}', actions=0xFFFF, accounts=['@ALL'], protocols=['all'])
    perm.users.add(plain_a); perm.assets.add(objs['A1'][0])
with tmp_to_org(org_b):
    perm_b = AssetPermission.objects.create(name=f'perm-b-{R}', actions=0xFFFF, accounts=['@ALL'], protocols=['all'])
    perm_b.users.add(plain_b); perm_b.assets.add(objs['B1'][0])

# every object of org B: its id is a canary for anyone not in org B
B_IDS = set()
with tmp_to_root_org():
    for model in apps.get_models():
        if 'org_id' not in {f.attname for f in model._meta.concrete_fields} or model._meta.proxy:
            continue
        try:
            B_IDS |= {str(i) for i in model.objects.filter(org_id=org_b.id).values_list('pk', flat=True)[:500]}
        except Exception:
            pass
B_IDS.discard(str(org_b.id))
print(f'WORLD orgs A={org_a.id} B={org_b.id} b_ids={len(B_IDS)}', flush=True)


# ------------------------------------------------------------------ clients
def client(user):
    c = Client(HTTP_HOST='localhost', raise_request_exception=False)
    if user:
        c.force_login(user)
    return c


IDENT = {'anonymous': (None, None), 'plainA': (plain_a, org_a), 'orgadminA': (orgadmin_a, org_a),
         'auditorA': (auditor_a, org_a), 'svc': (svc, None), 'admin': (admin, None)}
CLIENTS = {k: client(u) for k, (u, _) in IDENT.items()}


class Timeout(Exception):
    pass


def _alarm(*_):
    raise Timeout()


signal.signal(signal.SIGALRM, _alarm)


def call(who, method, path, org=None, data=None):
    c = CLIENTS[who]
    extra = {'HTTP_X_JMS_ORG': str(org)} if org else {}
    signal.alarm(8)
    try:
        fn = getattr(c, method.lower())
        if method in ('GET', 'DELETE'):
            r = fn(path, **extra)
        else:
            r = fn(path, data=json.dumps(data if data is not None else {}), content_type=J, **extra)
        body = r.content.decode('utf-8', 'ignore') if hasattr(r, 'content') else ''
        return r.status_code, body
    except Timeout:
        return 'timeout', ''
    except Exception as e:
        return 'error', f'{type(e).__name__}: {e}'
    finally:
        signal.alarm(0)


# ------------------------------------------------------------------ the URLs
def walk(patterns, prefix=''):
    for p in patterns:
        if isinstance(p, URLResolver):
            yield from walk(p.url_patterns, prefix + str(p.pattern))
        elif isinstance(p, URLPattern):
            yield prefix + str(p.pattern), p


def view_model(callback):
    cls = getattr(callback, 'cls', None) or getattr(callback, 'view_class', None)
    if not cls:
        return None
    qs = getattr(cls, 'queryset', None)
    if qs is not None and hasattr(qs, 'model'):
        return qs.model
    if getattr(cls, 'model', None):
        return cls.model
    ser = getattr(cls, 'serializer_class', None)
    meta = getattr(ser, 'Meta', None)
    return getattr(meta, 'model', None)


SKIP = re.compile(r'(\(\?P<format>|health|prometheus|logout|/ws/|export|download|terminal-registrations|'
                  r'service-account-registrations|chat-ai|\.(?:json|yaml))', re.I)
PARAM = re.compile(r'\(\?P<(\w+)>[^)]*\)|<(?:\w+:)?(\w+)>')


def b_object(model):
    if model is None:
        return None
    try:
        with tmp_to_root_org():
            if 'org_id' in {f.attname for f in model._meta.concrete_fields}:
                return model.objects.filter(org_id=org_b.id).first()
    except Exception:
        return None
    return None


routes = []
for raw, p in walk(get_resolver().url_patterns):
    path = '/' + raw.replace('^', '').replace('$', '').replace('\\', '')
    if not path.startswith('/api/v1/') or SKIP.search(path):
        continue
    names = [a or b for a, b in PARAM.findall(path)]
    routes.append((path, names, view_model(p.callback)))
print(f'ROUTES {len(routes)}', flush=True)


def leaked(body, who):
    hits = [k for k, v in CANARY.items() if v in body]
    if who in ('plainA', 'orgadminA', 'auditorA') and any(i in body for i in list(B_IDS)[:2000]):
        hits.append('orgB-object')
    return hits


def concrete(path, names, obj):
    for n in names:
        val = str(obj.pk) if obj is not None else str(uuid.uuid4())
        path = PARAM.sub(val, path, count=1)
    return path


# ------------------------------------------------------------------ 1. reads
t0 = time.time()
for path, names, model in routes:
    obj = b_object(model) if names else None
    if names and obj is None:
        continue
    url = concrete(path, names, obj)
    for who, (user, own) in IDENT.items():
        if who == 'admin':
            continue
        for org in ([None] if who in ('anonymous', 'svc') else [own.id, org_b.id, 'ROOT']):
            st, body = call(who, 'GET', url, org)
            if isinstance(st, int) and 200 <= st < 300:
                hits = leaked(body, who)
                if who == 'svc':
                    hits = [h for h in hits if h != 'orgB-object']
                if hits:
                    finding('read-leak', who, org, 'GET', url, st, ','.join(hits))
                elif who == 'anonymous' and body.strip() not in ('', '[]', '{}'):
                    finding('anonymous-read', who, org, 'GET', url, st, body[:120])
print(f'READS done {int(time.time() - t0)}s', flush=True)

# ------------------------------------------------------------------ 2. writes (create / change) by the low identities
for path, names, model in routes:
    for who in ('plainA', 'auditorA', 'svc'):
        user, own = IDENT[who]
        orgs = [None] if who == 'svc' else [own.id, 'ROOT']
        if not names:
            for org in orgs + ([] if who == 'svc' else [org_b.id]):
                st, body = call(who, 'POST', path, org, {'username': 'cb', 'query': 'cb', 'q': 'cb'})
                if isinstance(st, int) and 200 <= st < 300:
                    hits = leaked(body, who)
                    finding('post-leak' if hits else 'write-accepted', who, org, 'POST', path, st,
                            (','.join(hits) + ' ' if hits else '') + body[:160])
        else:
            obj = b_object(model)
            if obj is None:
                continue
            url = concrete(path, names, obj)
            for org in orgs + ([] if who == 'svc' else [org_b.id]):
                for method in ('PATCH', 'PUT'):
                    st, body = call(who, method, url, org, {})
                    if isinstance(st, int) and 200 <= st < 300:
                        finding('write-accepted', who, org, method, url, st, body[:160])
# org admin of A against org B's objects
for path, names, model in routes:
    if not names:
        continue
    obj = b_object(model)
    if obj is None:
        continue
    url = concrete(path, names, obj)
    for org in (org_a.id, org_b.id, 'ROOT'):
        for method in ('PATCH', 'PUT'):
            st, body = call('orgadminA', method, url, org, {})
            if isinstance(st, int) and 200 <= st < 300:
                finding('cross-org-write', 'orgadminA', org, method, url, st, body[:160])
print(f'WRITES done {int(time.time() - t0)}s', flush=True)

# ------------------------------------------------------------------ 3. targeted escalations
sysadmin_role = BuiltinRole.system_admin.get_role()
orgadmin_role = BuiltinRole.org_admin.get_role()


def is_sysadmin(u):
    u = User.objects.get(pk=u.pk)
    return RoleBinding.objects.filter(user=u, role=sysadmin_role).exists() or u.is_superuser


def escalate(name, who, method, path, data, org, check):
    st, body = call(who, method, path, org, data)
    ok = check()
    print(f'ESCALATION {name}: {st} {"ESCALATED" if ok else "refused"}', flush=True)
    if ok:
        finding('escalation', who, org, method, path, st, name + ' ' + body[:200])


escalate('plainA sets own system roles via profile', 'plainA', 'PATCH', '/api/v1/users/profile/',
         {'system_roles': [str(sysadmin_role.id)], 'is_superuser': True}, org_a.id, lambda: is_sysadmin(plain_a))
escalate('plainA binds system admin to self', 'plainA', 'POST', '/api/v1/rbac/system-role-bindings/',
         {'user': str(plain_a.id), 'role': str(sysadmin_role.id)}, org_a.id, lambda: is_sysadmin(plain_a))
escalate('orgadminA binds system admin to self', 'orgadminA', 'POST', '/api/v1/rbac/system-role-bindings/',
         {'user': str(orgadmin_a.id), 'role': str(sysadmin_role.id)}, org_a.id, lambda: is_sysadmin(orgadmin_a))
escalate('orgadminA sets own system roles', 'orgadminA', 'PATCH', f'/api/v1/users/users/{orgadmin_a.id}/',
         {'system_roles': [str(sysadmin_role.id)]}, org_a.id, lambda: is_sysadmin(orgadmin_a))
escalate('orgadminA creates a system admin', 'orgadminA', 'POST', '/api/v1/users/users/',
         {'username': f'evil-{R}', 'name': 'evil', 'email': f'evil-{R}@example.com', 'password_strategy': 'custom',
          'password': 'Evil-Passw0rd-123!', 'system_roles': [str(sysadmin_role.id)],
          'org_roles': [str(orgadmin_role.id)]}, org_a.id,
         lambda: User.objects.filter(username=f'evil-{R}').exists() and is_sysadmin(User.objects.get(username=f'evil-{R}')))
escalate('orgadminA makes self admin of org B', 'orgadminA', 'POST', '/api/v1/rbac/org-role-bindings/',
         {'user': str(orgadmin_a.id), 'role': str(orgadmin_role.id)}, org_b.id,
         lambda: RoleBinding.objects.filter(user=orgadmin_a, org_id=org_b.id).exists())
email_before = User.objects.get(pk=admin.pk).email
escalate('orgadminA changes the system admin email', 'orgadminA', 'PATCH', f'/api/v1/users/users/{admin.id}/',
         {'email': f'takeover-{R}@example.com'}, org_a.id, lambda: User.objects.get(pk=admin.pk).email != email_before)
escalate('orgadminA changes plainB (org B only) email', 'orgadminA', 'PATCH', f'/api/v1/users/users/{plain_b.id}/',
         {'email': f'takeover-b-{R}@example.com'}, org_a.id, lambda: User.objects.get(pk=plain_b.pk).email != CANARY['email_B'])
escalate('orgadminA resets the system admin password', 'orgadminA', 'PATCH', f'/api/v1/users/users/{admin.id}/',
         {'password_strategy': 'custom', 'password': 'Takeover-Passw0rd-123!'}, org_a.id,
         lambda: User.objects.get(pk=admin.pk).check_password('Takeover-Passw0rd-123!'))
escalate('plainA reads org B account secret', 'plainA', 'GET', f'/api/v1/accounts/account-secrets/{objs["B1"][1].id}/',
         None, org_b.id, lambda: False)
for who, org in (('plainA', org_a.id), ('plainA', org_b.id), ('orgadminA', org_b.id), ('auditorA', org_a.id)):
    for acc in ('A1', 'A2', 'B1'):
        st, body = call(who, 'GET', f'/api/v1/accounts/account-secrets/{objs[acc][1].id}/', org)
        if CANARY['secret_' + ('B' if acc == 'B1' else acc)] in body:
            finding('secret-read', who, org, 'GET', f'account-secrets/{acc}', st, 'secret returned')
# connection token for an asset the user is not permitted
for acc in ('A2', 'B1'):
    h, a = objs[acc]
    for org in (org_a.id, org_b.id):
        st, body = call('plainA', 'POST', '/api/v1/authentication/connection-token/', org,
                        {'asset': str(h.id), 'account': a.name, 'protocol': 'ssh', 'connect_method': 'web_cli',
                         'input_username': 'root'})
        if isinstance(st, int) and 200 <= st < 300:
            finding('connect-unpermitted', 'plainA', org, 'POST', f'connection-token {acc}', st, body[:200])
        print(f'ESCALATION plainA connection token for {acc} (org {org}): {st}', flush=True)
st, body = call('svc', 'GET', '/api/v1/settings/setting/?category=security', None)
print(f'ESCALATION svc reads security settings: {st}', flush=True)
st, body = call('svc', 'PATCH', '/api/v1/settings/setting/?category=security', None, {'SECURITY_MFA_AUTH': 0})
if isinstance(st, int) and 200 <= st < 300:
    finding('escalation', 'svc', None, 'PATCH', '/api/v1/settings/setting/?category=security', st, 'service account changed settings')

# ------------------------------------------------------------------ 3b. normal use still works
def func(name, ok):
    print(f'FUNC {name}: {"ok" if ok else "BROKEN"}', flush=True)
    if not ok:
        finding('broken', '-', None, '-', name, '-', '')


def ids_in(who, path, org):
    st, body = call(who, 'GET', path, org)
    print(f'  ({who} {path} org={str(org)[:8]}: {st} {body[:160]!r})', flush=True)
    try:
        data = json.loads(body)
    except Exception:
        return st, set()
    rows = data.get('results', data) if isinstance(data, dict) else data
    return st, {str(r.get('id')) for r in rows if isinstance(r, dict)}


A1, A2, B1 = (str(objs[n][0].id) for n in ('A1', 'A2', 'B1'))
st, got = ids_in('plainA', '/api/v1/perms/users/self/assets/', org_a.id)
func('plainA sees their permitted asset in org A', st == 200 and A1 in got and A2 not in got)
st, got = ids_in('plainA', '/api/v1/perms/users/self/assets/', 'ROOT')
func('plainA "all organizations" view still works', st == 200 and A1 in got and B1 not in got)
st, got = ids_in('plainA', '/api/v1/perms/users/self/assets/', org_b.id)
func('plainA asking for org B gets their own org (A1), not B', st == 200 and B1 not in got)
st, got = ids_in('orgadminA', '/api/v1/accounts/accounts/', org_a.id)
func('orgadminA lists the accounts of org A', st == 200 and str(objs['A1'][1].id) in got and str(objs['B1'][1].id) not in got)
st, got = ids_in('admin', '/api/v1/accounts/accounts/', org_b.id)
func('admin lists the accounts of org B', st == 200 and str(objs['B1'][1].id) in got)
st, got = ids_in('admin', '/api/v1/assets/assets/', 'ROOT')
func('admin sees every organization in root', st == 200 and {A1, A2, B1} <= got)
st, got = ids_in('plainA', '/api/v1/tickets/apply-assets/suggestions/', 'ROOT')
func('plainA request form offers their org\'s assets in "all organizations", not org B\'s', st == 200 and A2 in got and B1 not in got)
st, got = ids_in('plainA', '/api/v1/tickets/apply-assets/suggestions/', org_a.id)
func('plainA request form offers their org\'s assets', st == 200 and A2 in got)
st, body = call('orgadminA', 'POST', '/api/v1/accounts/accounts/username-suggestions/', org_a.id, {'username': ''})
func('orgadminA username suggestions (asset permission form) still work', st == 200)

# ------------------------------------------------------------------ 4. deletes (last: they change the world)
for path, names, model in routes:
    if not names:
        continue
    obj = b_object(model)
    if obj is None:
        continue
    url = concrete(path, names, obj)
    for who, org in (('plainA', org_a.id), ('plainA', org_b.id), ('plainA', 'ROOT'), ('auditorA', org_a.id),
                     ('orgadminA', org_a.id), ('orgadminA', org_b.id), ('orgadminA', 'ROOT'), ('svc', None)):
        st, body = call(who, 'DELETE', url, org)
        if isinstance(st, int) and 200 <= st < 300:
            finding('delete-accepted', who, org, 'DELETE', url, st, body[:120])
            break
print(f'DONE {int(time.time() - t0)}s', flush=True)
