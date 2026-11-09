# Checks for the 2026-11-09 review findings (run in `manage.py shell` on a throwaway database;
# tests/security/review_fixes_run.sh). Each check prints "PASS <name>" or "FAIL <name> <detail>"; positive controls
# make sure a fix did not simply switch the feature off.
#   dashboard days    /api/v1/index/ clamps ?days= (no huge allocation, no 500 on junk)
#   dashboard org     an org admin's login-per-day series counts only the org's members
#   search org        global search returns users of the current org only (root: all)
#   jit match org     /accounts/jit-policies/match/?user= refuses a user of another org
#   vault connection  changing a connection's address needs the secret again (omitted or masked)
#   vault testing     "test connection" with a new address never sends the stored token there
#   ssh-ca testing    same for the SSH CA OpenBao test
#   health            /api/health/ answers status only (no timings), 200 when healthy
#   sdk demos         the integration-application SDK examples are still served
import json
import secrets as pysecrets
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

from django.test import Client, override_settings

import xpack.utils as xu
xu.get_license_user_limit = lambda *a, **k: 1000
xu.has_ticket_license = lambda *a, **k: True

from accounts.models import VaultConnection
from accounts.serializers.vault_routing import VaultConnectionSerializer
from audits.models import UserLoginLog
from orgs.models import Organization
from rbac.builtin import BuiltinRole
from rbac.models import RoleBinding
from users.models import User

R = pysecrets.token_hex(4)
J = 'application/json'
results = []


def check(name, ok, detail=''):
    ok = bool(ok)
    results.append(ok)
    print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else ' ' + str(detail)[:400]), flush=True)


BuiltinRole.sync_to_db()
org_a = Organization.objects.create(name=f'org-a-{R}')
org_b = Organization.objects.create(name=f'org-b-{R}')
admin = User.objects.get(username='admin')
User.objects.filter(username='admin').update(is_first_login=False)


def mk_user(name, org, role):
    u = User.objects.create(username=name, name=name, email=f'{name}@example.com', is_first_login=False)
    u.set_password(pysecrets.token_urlsafe(16)); u.save()
    u.system_roles.add_role_system_user()
    RoleBinding.objects.create(user=u, role=role.get_role(), org=org, scope='org')
    return u


orgadmin_a = mk_user(f'orgadmina{R}', org_a, BuiltinRole.org_admin)
auditor_a = mk_user(f'auditora{R}', org_a, BuiltinRole.org_auditor)
user_a = mk_user(f'zzcanarya{R}', org_a, BuiltinRole.org_user)
user_b = mk_user(f'zzcanaryb{R}', org_b, BuiltinRole.org_user)


def client(user=None):
    c = Client(HTTP_HOST='localhost', raise_request_exception=False)
    if user:
        c.force_login(user)
    return c


ADMIN, OA, AUD, ANON = client(admin), client(orgadmin_a), client(auditor_a), client()


def get(c, path, org=None):
    extra = {'HTTP_X_JMS_ORG': str(org)} if org else {}
    r = c.get(path, **extra)
    return r.status_code, r.content.decode('utf-8', 'ignore')


def post(c, path, data, org=None):
    extra = {'HTTP_X_JMS_ORG': str(org)} if org else {}
    r = c.post(path, data=json.dumps(data), content_type=J, **extra)
    return r.status_code, r.content.decode('utf-8', 'ignore')


# ---------------------------------------------------------------- dashboard: days
for days in ('50000000', 'abc', '-5', '99999999999999999999999'):
    t = time.time()
    st, body = get(ADMIN, f'/api/v1/index/?dates_metrics=1&session_dates_metrics=1&days={days}', 'ROOT')
    took = time.time() - t
    n = len(json.loads(body).get('dates_metrics_date', [])) if st == 200 else -1
    check(f'dashboard days={days[:12]}', st == 200 and took < 10 and 1 <= n <= 365, (st, round(took, 1), n, body[:150]))
st, body = get(ADMIN, '/api/v1/index/?dates_metrics=1&days=30', 'ROOT')
check('dashboard days=30 (control: 30 dates)', st == 200 and len(json.loads(body).get('dates_metrics_date', [])) == 30, body[:150])

# ---------------------------------------------------------------- dashboard: org login series
from django.utils import timezone
for u in (user_b, user_b, user_b):
    UserLoginLog.objects.create(username=f'{u.name}({u.username})', type='W', ip='10.0.0.1', status=True,
                                datetime=timezone.now(), backend='Password')
UserLoginLog.objects.create(username=f'{user_a.name}({user_a.username})', type='W', ip='10.0.0.2', status=True,
                            datetime=timezone.now(), backend='Password')


def login_today(c, org):
    st, body = get(c, '/api/v1/index/?dates_metrics=1&days=7', org)
    data = json.loads(body) if st == 200 else {}
    key = next((k for k in data if 'login' in k and k.startswith('dates_metrics')), None)
    # the whole 7-day series: the dashboard buckets days in UTC while "today" is the local date, so between
    # 16:00 and 24:00 UTC (TIME_ZONE Asia/Shanghai) today's logins sit in another bucket
    return st, (sum(x or 0 for x in data.get(key)) if key and data.get(key) else None), key


seen_any = False
for who, c in (('org admin', OA), ('org auditor', AUD)):
    st, today_a, key = login_today(c, org_a.id)
    if st == 403:
        print(f'INFO dashboard: {who} of org A may not read /api/v1/index/ (403)', flush=True)
        continue
    seen_any = True
    check(f'dashboard {who} A: 7-day logins count only org A (1)', st == 200 and today_a == 1, (st, key, today_a))
if not seen_any:
    print('INFO dashboard: no org-scoped role reads the dashboard; the cross-org count is not reachable', flush=True)
st, today_root, key = login_today(ADMIN, 'ROOT')
check('dashboard root admin: 7-day logins count every org (>=4)', st == 200 and (today_root or 0) >= 4, (st, key, today_root))

# ---------------------------------------------------------------- global search
st, body = get(OA, f'/api/v1/search/?q=zzcanaryb{R}', org_a.id)
check('search org admin A: no user of org B', st == 200 and str(user_b.id) not in body, (st, body[:200]))
st, body = get(OA, f'/api/v1/search/?q=zzcanarya{R}', org_a.id)
check('search org admin A: finds own org user (control)', st == 200 and str(user_a.id) in body, (st, body[:200]))
st, body = get(ADMIN, f'/api/v1/search/?q=zzcanaryb{R}', 'ROOT')
check('search root admin: finds org B user (control)', st == 200 and str(user_b.id) in body, (st, body[:200]))

# ---------------------------------------------------------------- jit match
st, body = get(OA, f'/api/v1/accounts/jit-policies/match/?user={user_b.id}', org_a.id)
check('jit match org admin A: user of org B refused', st == 400 and 'user' in body.lower(), (st, body[:200]))
st, body = get(OA, f'/api/v1/accounts/jit-policies/match/?user={user_a.id}', org_a.id)
check('jit match org admin A: own org user accepted (control)', not (st == 400 and 'Choose a user' in body), (st, body[:200]))


# ---------------------------------------------------------------- a local listener that records the tokens it is sent
class Rec(BaseHTTPRequestHandler):
    seen = []

    def _any(self):
        Rec.seen.append((self.server.server_port, self.headers.get('X-Vault-Token')))
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers()
        self.wfile.write(b'{"initialized": true, "sealed": false, "data": {}}')

    do_GET = do_POST = do_PUT = do_LIST = _any

    def log_message(self, *a):
        pass


def listener():
    srv = HTTPServer(('127.0.0.1', 0), Rec)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, f'http://127.0.0.1:{srv.server_port}'


stored_srv, stored_url = listener()
evil_srv, evil_url = listener()


def tokens_at(srv):
    return {tok for port, tok in Rec.seen if port == srv.server_port}


# ---------------------------------------------------------------- vault testing API
with override_settings(VAULT_LOCKED=False, VAULT_ENABLED=True, VAULT_BACKEND='openbao',
                       VAULT_OPENBAO_ADDR=stored_url, VAULT_OPENBAO_TOKEN='stored-vault-token'):
    Rec.seen.clear()
    st, body = post(ADMIN, '/api/v1/settings/vault/openbao/testing/', {'VAULT_OPENBAO_ADDR': evil_url}, 'ROOT')
    check('vault testing: new address is contacted without the stored token',
          tokens_at(evil_srv) and 'stored-vault-token' not in tokens_at(evil_srv), (st, Rec.seen[:5], body[:200]))
    Rec.seen.clear()
    st, body = post(ADMIN, '/api/v1/settings/vault/openbao/testing/', {'VAULT_OPENBAO_ADDR': stored_url}, 'ROOT')
    check('vault testing: configured address still uses the stored token (control)',
          'stored-vault-token' in tokens_at(stored_srv), (st, Rec.seen[:5], body[:200]))

# ---------------------------------------------------------------- SSH CA testing API
with override_settings(SSH_CA_OPENBAO_ADDR=stored_url, SSH_CA_OPENBAO_TOKEN='stored-ssh-token'):
    Rec.seen.clear()
    st, body = post(ADMIN, '/api/v1/settings/ssh-ca/openbao/testing/', {'SSH_CA_OPENBAO_ADDR': evil_url}, 'ROOT')
    check('ssh-ca testing: new address is contacted without the stored token',
          tokens_at(evil_srv) and 'stored-ssh-token' not in tokens_at(evil_srv), (st, Rec.seen[:5], body[:200]))
    Rec.seen.clear()
    st, body = post(ADMIN, '/api/v1/settings/ssh-ca/openbao/testing/', {'SSH_CA_OPENBAO_ADDR': stored_url}, 'ROOT')
    check('ssh-ca testing: configured address still uses the stored token (control)',
          'stored-ssh-token' in tokens_at(stored_srv), (st, Rec.seen[:5], body[:200]))
    from authentication.services.ssh_certificate import get_ssh_ca_client
    try:
        Rec.seen.clear()
        ok, err = get_ssh_ca_client().is_active()
        check('ssh-ca client (signing path) builds and reaches the configured address',
              'stored-ssh-token' in tokens_at(stored_srv), (ok, err, Rec.seen[:5]))
    except Exception as e:
        check('ssh-ca client (signing path) builds and reaches the configured address', False, repr(e))
    st, body = post(ADMIN, '/api/v1/settings/ssh-ca/openbao/testing/', {'SSH_CA_OPENBAO_ADDR': 'not a url'}, 'ROOT')
    check('ssh-ca testing: invalid address is a 400', st == 400, (st, body[:200]))

# ---------------------------------------------------------------- vault connection: address change needs the secret
with override_settings(VAULT_LOCKED=False):
    conn = VaultConnection.objects.create(name=f'conn-{R}', type='openbao', config={
        'VAULT_OPENBAO_ADDR': stored_url, 'VAULT_OPENBAO_TOKEN': 'stored-conn-token', 'VAULT_OPENBAO_MOUNT_POINT': 'kv'})

    def update(cfg):
        conn.refresh_from_db()
        s = VaultConnectionSerializer(instance=conn, data={'config': cfg}, partial=True)
        ok = s.is_valid()
        return ok, (s.validated_data.get('config') if ok else s.errors)

    ok, out = update({'VAULT_OPENBAO_ADDR': evil_url, 'VAULT_OPENBAO_TOKEN': '******'})
    check('vault connection: new address + masked token refused', not ok, out)
    ok, out = update({'VAULT_OPENBAO_ADDR': evil_url})
    check('vault connection: new address + omitted token refused', not ok, out)
    ok, out = update({'VAULT_OPENBAO_ADDR': evil_url, 'VAULT_OPENBAO_TOKEN': 'new-token'})
    check('vault connection: new address + new token accepted', ok and out.get('VAULT_OPENBAO_TOKEN') == 'new-token', out)
    ok, out = update({'VAULT_OPENBAO_ADDR': evil_url, 'VAULT_OPENBAO_TOKEN': ''})
    check('vault connection: new address + cleared token accepted (no reuse)', ok and not out.get('VAULT_OPENBAO_TOKEN'), out)
    ok, out = update({'VAULT_OPENBAO_ADDR': stored_url + '/', 'VAULT_OPENBAO_TOKEN': '******'})
    check('vault connection: same address + masked token keeps it (control)',
          ok and out.get('VAULT_OPENBAO_TOKEN') == 'stored-conn-token', out)
    ok, out = update({'VAULT_OPENBAO_MOUNT_POINT': 'kv2'})
    check('vault connection: other field change keeps the token (control)',
          ok and out.get('VAULT_OPENBAO_TOKEN') == 'stored-conn-token', out)

# ---------------------------------------------------------------- health
st, body = get(ANON, '/api/health/')
data = json.loads(body) if st == 200 else {}
check('health: 200 and status true', st == 200 and data.get('status') is True, (st, body[:200]))
check('health: no db/redis timings or server time', not {'db_time', 'redis_time', 'time'} & set(data), sorted(data))
st2, body2 = get(ANON, '/api/v1/health/')
check('health: second call (cached) still 200', st2 == 200 and json.loads(body2).get('status') is True, (st2, body2[:200]))

# ---------------------------------------------------------------- SDK demos
for lang in ('python', 'curl'):
    st, body = get(ADMIN, f'/api/v1/accounts/integration-applications/sdks/?language={lang}', 'ROOT')
    data = json.loads(body) if st == 200 else {}
    check(f'sdk demos ({lang}): readme and code served', st == 200 and data.get('code') and data.get('readme'),
          (st, body[:200]))

print(f'DONE {sum(results)}/{len(results)} passed', flush=True)
