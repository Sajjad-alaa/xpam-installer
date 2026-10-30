# API timings with realistic data (run in `manage.py shell` on a throwaway database; tests/perf/api_perf_run.sh):
# seeds assets, accounts, users, groups, permissions and nodes through the API, then times the console's main
# lists. For each: milliseconds and database queries at 15 and 100 rows: queries that grow with the rows are an
# N+1 to fix. Output: "PERF <endpoint> rows=<n> ms=<t> queries=<q>".
import json
import statistics
import time

from django.db import connection
from django.test import Client
from django.test.utils import CaptureQueriesContext

import xpack.utils as xu
xu.get_license_user_limit = lambda *a, **k: 100000
for _name in ('get_license_asset_limit', 'get_license_asset_count'):
    if hasattr(xu, _name):
        setattr(xu, _name, lambda *a, **k: 1000000)
xu.has_ticket_license = lambda *a, **k: True
import importlib
importlib.import_module('assets.api.asset.asset').get_license_asset_limit = lambda *a, **k: 1000000

from assets.models import Node, Platform
from orgs.models import Organization
from orgs.utils import tmp_to_org
from rbac.builtin import BuiltinRole
from users.models import User

N_ASSETS, N_USERS, N_GROUPS, N_PERMS = int(__import__('os').environ.get('N_ASSETS', 400)), 120, 12, 40
J = 'application/json'
BuiltinRole.sync_to_db()
admin = User.objects.get(username='admin')
User.objects.filter(username='admin').update(is_first_login=False)
c = Client(HTTP_HOST='localhost', raise_request_exception=True)
c.force_login(admin)
org = Organization.default()
H = {'HTTP_X_JMS_ORG': str(org.id)}


def post(path, data):
    r = c.post(path, data=json.dumps(data), content_type=J, **H)
    assert r.status_code in (200, 201), (path, r.status_code, r.content[:300])
    return r.json()


t0 = time.time()
linux = Platform.objects.filter(name='Linux').first()
with tmp_to_org(org):
    root = Node.org_root()
nodes = [post('/api/v1/assets/nodes/', {'value': f'team-{i}', 'parent': str(root.id)})['id'] for i in range(10)] \
    if False else []
with tmp_to_org(org):
    nodes = [str(root.create_child(value=f'team-{i}').id) for i in range(10)]
assets = []
for i in range(N_ASSETS):
    a = post('/api/v1/assets/hosts/', {
        'name': f'host-{i:04d}', 'address': f'10.{i // 250}.{i % 250}.1', 'platform': linux.id,
        'nodes': [nodes[i % len(nodes)]], 'protocols': [{'name': 'ssh', 'port': 22}],
        'accounts': [{'name': f'root-{i}', 'username': 'root', 'secret_type': 'password', 'secret': f'pw-{i}',
                      'privileged': True},
                     {'name': f'app-{i}', 'username': f'app{i % 7}', 'secret_type': 'password', 'secret': f'apw-{i}'}]})
    assets.append(a['id'])
users = []
for i in range(N_USERS):
    u = post('/api/v1/users/users/', {'username': f'user{i:03d}', 'name': f'User {i}', 'email': f'user{i}@example.com',
                                      'password_strategy': 'custom', 'password': f'Passw0rd-{i}-Abc!',
                                      'system_roles': [str(BuiltinRole.system_user.id)],
                                      'org_roles': [str(BuiltinRole.org_user.id)]})
    users.append(u['id'])
groups = [post('/api/v1/users/groups/', {'name': f'group-{i}', 'users': users[i::N_GROUPS]})['id'] for i in range(N_GROUPS)]
for i in range(N_PERMS):
    post('/api/v1/perms/asset-permissions/', {
        'name': f'perm-{i}', 'users': users[i::N_PERMS][:5], 'user_groups': [groups[i % N_GROUPS]],
        'assets': assets[i::N_PERMS][:20], 'nodes': [nodes[i % len(nodes)]], 'accounts': ['@ALL'],
        'protocols': ['all'], 'actions': ['all'], 'is_active': True})
print(f'SEEDED assets={N_ASSETS} accounts={2 * N_ASSETS} users={N_USERS} groups={N_GROUPS} perms={N_PERMS} '
      f'in {int(time.time() - t0)}s', flush=True)

plain = User.objects.get(id=users[0])
cp = Client(HTTP_HOST='localhost', raise_request_exception=True)
cp.force_login(plain)

LISTS = [
    ('admin', '/api/v1/assets/assets/'),
    ('admin', '/api/v1/assets/hosts/'),
    ('admin', '/api/v1/accounts/accounts/'),
    ('admin', '/api/v1/users/users/'),
    ('admin', '/api/v1/users/groups/'),
    ('admin', '/api/v1/perms/asset-permissions/'),
    ('admin', '/api/v1/assets/nodes/'),
    ('admin', '/api/v1/assets/nodes/children/tree/?assets=1'),
    ('admin', '/api/v1/accounts/account-templates/'),
    ('admin', '/api/v1/audits/login-logs/'),
    ('admin', '/api/v1/audits/operate-logs/'),
    ('admin', '/api/v1/terminal/sessions/'),
    ('admin', '/api/v1/tickets/tickets/'),
    ('admin', '/api/v1/accounts/jit-policies/'),
    ('plain', '/api/v1/perms/users/self/assets/'),
    ('plain', '/api/v1/perms/users/self/nodes/children-with-assets/tree/'),
    ('plain', '/api/v1/perms/users/self/nodes/all-with-assets/tree/'),
]


def measure(who, path, limit):
    client = c if who == 'admin' else cp
    sep = '&' if '?' in path else '?'
    url = f'{path}{sep}limit={limit}&offset=0' if 'tree' not in path else path
    times, queries, status = [], 0, None
    for i in range(4):
        with CaptureQueriesContext(connection) as ctx:
            t = time.perf_counter()
            r = client.get(url, **H)
            times.append((time.perf_counter() - t) * 1000)
        status, queries = r.status_code, len(ctx.captured_queries)
    return status, statistics.median(times[1:]), queries  # (the first call warms caches)


for who, path in LISTS:
    for limit in (15, 100):
        st, ms, q = measure(who, path, limit)
        print(f'PERF {who:5} {path:58} rows={limit:3} status={st} ms={ms:7.1f} queries={q}', flush=True)
        if 'tree' in path:
            break
print('DONE', flush=True)
