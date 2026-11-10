# Performance benchmark, part 1 (run in `manage.py shell` on a throwaway database; tests/perf/bench_run.sh):
# seeds a realistic data set, then calls the most used API endpoints in-process and prints, per endpoint, the
# first (cold) time, the median of the next calls (warm) and the number of SQL queries per call.
#   seed: 30 asset groups (5 x 6), 600 hosts with an SSH protocol and one account each, 50 users,
#         a permission giving "bench" 10 of the groups (~200 assets) with every account
#   PROFILE <name> cold=<ms> warm=<ms> queries=<n> status=<code> bytes=<n>
import json
import os
import random
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
import importlib; _asset_api = importlib.import_module('assets.api.asset.asset')
_asset_api.get_license_asset_limit = lambda *a, **k: 1000000

from accounts.models import Account
from assets.models import Asset, Node, Platform
from orgs.models import Organization
from orgs.utils import tmp_to_org
from perms.models import AssetPermission
from rbac.builtin import BuiltinRole
from users.models import User

random.seed(7)
J = 'application/json'
PASSWORD = os.environ.get('BENCH_PASSWORD', 'Bench-Only-Pass-2026')
SEED = os.environ.get('BENCH_SEED', '1') == '1'

BuiltinRole.sync_to_db()
org = Organization.default()
admin = User.objects.get(username='admin')
admin.set_password(PASSWORD); admin.is_first_login = False; admin.need_update_password = False; admin.save()
admin_client = Client(HTTP_HOST='localhost')
admin_client.force_login(admin)

if SEED and not User.objects.filter(username='bench').exists():
    t0 = time.time()
    with tmp_to_org(org):
        root = Node.org_root()
        leaves = []
        for i in range(5):
            top = root.create_child(value=f'group-{i}')
            leaves += [top.create_child(value=f'group-{i}-{j}') for j in range(6)]
    linux = Platform.objects.filter(name='Linux').first()
    for n in range(600):
        node = leaves[n % len(leaves)]
        r = admin_client.post('/api/v1/assets/hosts/', data=json.dumps({
            'name': f'host-{n:04d}', 'address': f'10.{n // 250}.{n % 250}.{(n * 7) % 250 + 1}', 'platform': linux.id,
            'nodes': [str(node.id)], 'protocols': [{'name': 'ssh', 'port': 22}]}), content_type=J,
            HTTP_X_JMS_ORG=str(org.id))
        assert r.status_code == 201, (r.status_code, r.content[:200])
    with tmp_to_org(org):
        Account.objects.bulk_create([
            Account(asset=a, name='root', username='root', secret_type='password', secret=f'pw-{a.id.hex[:12]}',
                    org_id=org.id, privileged=True)
            for a in Asset.objects.all()])
    users = []
    for n in range(50):
        u = User.objects.create(username=f'user{n:02d}', name=f'User {n:02d}', email=f'user{n:02d}@example.com',
                                is_first_login=False)
        u.system_roles.add_role_system_user()
        users.append(u)
    bench = User.objects.create(username='bench', name='Bench', email='bench@example.com', is_first_login=False)
    bench.set_password(PASSWORD); bench.save()
    bench.system_roles.add_role_system_user()
    with tmp_to_org(org):
        org.add_member(bench)
        for u in users:
            org.add_member(u)
        perm = AssetPermission.objects.create(name='bench-perm', accounts=['@ALL'], actions=0xFFFF, org_id=org.id)
        perm.users.add(bench, *users[:10])
        perm.nodes.add(*leaves[:10])
    print(f'SEED done in {time.time() - t0:.0f}s: assets={Asset.objects.count()} nodes={Node.objects.count()} '
          f'accounts={Account.objects.count()} users={User.objects.count()}', flush=True)

bench = User.objects.get(username='bench')
bench_client = Client(HTTP_HOST='localhost')
bench_client.force_login(bench)

ENDPOINTS = [
    ('health', None, '/api/health/'),
    ('profile', 'admin', '/api/v1/users/profile/'),
    ('assets-list', 'admin', '/api/v1/assets/assets/?limit=50&offset=0'),
    ('accounts-list', 'admin', '/api/v1/accounts/accounts/?limit=50&offset=0'),
    ('users-list', 'admin', '/api/v1/users/users/?limit=50&offset=0'),
    ('node-tree', 'admin', '/api/v1/assets/nodes/children/tree/?assets=0'),
    ('dashboard', 'admin', '/api/v1/index/?total_count=1&dates_metrics=1&days=7'),
    ('sessions-list', 'admin', '/api/v1/terminal/sessions/?limit=20&offset=0'),
    ('my-tree', 'bench', '/api/v1/perms/users/self/nodes/children-with-assets/tree/'),
    ('my-assets', 'bench', '/api/v1/perms/users/self/assets/?limit=50&offset=0'),
    ('my-nodes', 'bench', '/api/v1/perms/users/self/nodes/?limit=50&offset=0'),
]
CLIENTS = {'admin': admin_client, 'bench': bench_client, None: Client(HTTP_HOST='localhost')}
WARM = int(os.environ.get('BENCH_WARM', '15'))

for name, who, path in ENDPOINTS:
    c = CLIENTS[who]
    extra = {'HTTP_X_JMS_ORG': str(org.id)} if who else {}
    times, queries, status, size = [], 0, 0, 0
    for i in range(WARM + 1):
        with CaptureQueriesContext(connection) as q:
            t = time.perf_counter()
            r = c.get(path, **extra)
            times.append((time.perf_counter() - t) * 1000)
        status, size, queries = r.status_code, len(r.content), len(q.captured_queries)
    print(f'PROFILE {name:14s} cold={times[0]:7.1f} warm={statistics.median(times[1:]):7.1f} '
          f'queries={queries:4d} status={status} bytes={size}', flush=True)
print('PROFILE done', flush=True)
