# Performance benchmark, part 3: function-level hot spots of the slowest endpoints (cProfile, source tree).
# Run after seed_profile.py in the same `manage.py shell` input (tests/perf/bench_run.sh with BENCH_HOTSPOTS=1).
import cProfile, io, pstats
from django.test import Client
from orgs.models import Organization
from users.models import User
org = Organization.default()
c = Client(HTTP_HOST='localhost'); c.force_login(User.objects.get(username='admin'))
for name, path in (('users-list', '/api/v1/users/users/?limit=50&offset=0'),
                   ('assets-list', '/api/v1/assets/assets/?limit=50&offset=0'),
                   ('accounts-list', '/api/v1/accounts/accounts/?limit=50&offset=0')):
    c.get(path, HTTP_X_JMS_ORG=str(org.id))
    pr = cProfile.Profile(); pr.enable()
    for _ in range(10):
        c.get(path, HTTP_X_JMS_ORG=str(org.id))
    pr.disable()
    s = io.StringIO(); st = pstats.Stats(pr, stream=s); st.sort_stats('cumulative').print_stats('/opt/core/apps', 22)
    print(f'HOT ===== {name} (10 calls): application functions by cumulative time')
    for l in s.getvalue().splitlines():
        if '/opt/core/apps' in l or 'cumtime' in l:
            print('HOT', l.replace('/opt/core/apps/', '')[:160])
    s = io.StringIO(); st = pstats.Stats(pr, stream=s); st.sort_stats('cumulative').print_stats('Cryptodome|encrypt|decrypt', 6)
    for l in s.getvalue().splitlines():
        if 'crypt' in l.lower() and 'percall' not in l:
            print('HOT crypto', l.replace('/opt/core/apps/', '')[:160])
