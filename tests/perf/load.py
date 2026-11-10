# Performance benchmark, part 2: HTTP load against a running core (tests/perf/bench_run.sh). For each endpoint:
# N requests with C concurrent clients, after a short warm-up. Prints
#   LOAD <name> p50=<ms> p95=<ms> rps=<n> errors=<n>
#   LOAD total rps=<n>
import os
import statistics
import sys
import time
from concurrent.futures import ThreadPoolExecutor

import requests

BASE = os.environ.get('BENCH_BASE', 'http://core:8080')
PASSWORD = os.environ.get('BENCH_PASSWORD', 'Bench-Only-Pass-2026')
N = int(os.environ.get('BENCH_N', '300'))
C = int(os.environ.get('BENCH_C', '8'))
ORG = os.environ.get('BENCH_ORG', '00000000-0000-0000-0000-000000000002')


def token(username):
    r = requests.post(BASE + '/api/v1/authentication/auth/', json={'username': username, 'password': PASSWORD},
                      timeout=30)
    r.raise_for_status()
    return r.json()['token']


HEADERS = {
    'admin': {'Authorization': 'Bearer ' + token('admin'), 'X-JMS-ORG': ORG},
    'bench': {'Authorization': 'Bearer ' + token('bench'), 'X-JMS-ORG': ORG},
    None: {},
}
ENDPOINTS = [
    ('health', None, '/api/health/'),
    ('profile', 'admin', '/api/v1/users/profile/'),
    ('assets-list', 'admin', '/api/v1/assets/assets/?limit=50&offset=0'),
    ('accounts-list', 'admin', '/api/v1/accounts/accounts/?limit=50&offset=0'),
    ('users-list', 'admin', '/api/v1/users/users/?limit=50&offset=0'),
    ('node-tree', 'admin', '/api/v1/assets/nodes/children/tree/?assets=0'),
    ('dashboard', 'admin', '/api/v1/index/?total_count=1&dates_metrics=1&days=7'),
    ('my-tree', 'bench', '/api/v1/perms/users/self/nodes/children-with-assets/tree/'),
    ('my-assets', 'bench', '/api/v1/perms/users/self/assets/?limit=50&offset=0'),
]

local = __import__('threading').local()


def session():
    if not hasattr(local, 's'):
        local.s = requests.Session()
    return local.s


def one(path, headers):
    t = time.perf_counter()
    try:
        r = session().get(BASE + path, headers=headers, timeout=60)
        ok = r.status_code == 200
    except requests.RequestException:
        ok = False
    return (time.perf_counter() - t) * 1000, ok


total_requests, total_time = 0, 0.0
for name, who, path in ENDPOINTS:
    h = HEADERS[who]
    for _ in range(5):
        one(path, h)
    t0 = time.perf_counter()
    with ThreadPoolExecutor(C) as ex:
        results = list(ex.map(lambda _: one(path, h), range(N)))
    wall = time.perf_counter() - t0
    lat = sorted(r[0] for r in results)
    errors = sum(1 for r in results if not r[1])
    total_requests += N; total_time += wall
    print(f'LOAD {name:14s} p50={statistics.median(lat):7.1f} p95={lat[int(len(lat) * 0.95) - 1]:7.1f} '
          f'rps={N / wall:7.1f} errors={errors}', flush=True)
print(f'LOAD total rps={total_requests / total_time:.1f}', flush=True)
sys.exit(0)
