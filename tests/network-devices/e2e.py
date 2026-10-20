"""Isolated test stack, XPAM 5.1.9: network device push / discovery / change secret / remove / JIT, per vendor."""
import os, sys, time, traceback
sys.path.insert(0, '/opt/jumpserver/apps'); os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'jumpserver.settings')
import django; django.setup()
from django.conf import settings
settings.ALLOWED_HOSTS = list(settings.ALLOWED_HOSTS) + ['testserver']
from rest_framework.test import APIClient
from users.models import User
import paramiko
from orgs.models import Organization
from orgs.utils import tmp_to_org, set_current_org
from assets.models import Platform, Device, Node
from accounts.models import Account, GatheredAccount, JITPolicy, JITAccount
from accounts.const import AutomationTypes
from accounts.tasks.common import quickstart_automation_by_snapshot
from accounts.tasks.push_account import push_accounts_to_assets_task
from accounts.tasks.remove_account import remove_accounts_task
from accounts.jit import targets
from accounts.jit.policy import unsupported_reason

EP = os.environ['EMU_PASSWORD']
CASES = [('FortiGate', 2201), ('PaloAlto', 2202), ('Cisco', 2203), ('Cisco-ASA', 2204), ('Cisco-NXOS', 2205),
         ('Juniper', 2206), ('Huawei', 2207), ('H3C', 2208)]
only = sys.argv[1:]
results = []


def check(name, ok, detail=''):
    results.append(bool(ok))
    print(('PASS ' if ok else 'FAIL ') + name + (f'  [{str(detail)[:250]}]' if detail != '' else ''), flush=True)


def login(port, user, pw):
    t = paramiko.Transport(('netemu', port))
    try:
        t.start_client(timeout=10)
        try:
            t.auth_password(user, pw)
        except paramiko.BadAuthenticationType:
            t.auth_interactive(user, lambda *a: [pw] * len(a[2]))
        return t.is_authenticated()
    except Exception:
        return False
    finally:
        t.close()


def last_error(execution):
    try:
        return {k: v for k, v in (execution.summary or {}).items()} or execution.result
    except Exception:
        return ''


org = Organization.default()
A = APIClient(); A.force_authenticate(User.objects.get(username='admin'))
H = {'HTTP_X_JMS_ORG': str(org.id)}
with tmp_to_org(org):
    root = Node.org_root()
    for name, port in CASES:
        if only and name not in only:
            continue
        print(f'== {name}', flush=True)
        t0 = time.time()
        asset = None
        try:
            platform = Platform.objects.get(name=name)
            r = A.post('/api/v1/assets/devices/', {
                'name': f'emu-{name}', 'address': 'netemu', 'platform': platform.id, 'nodes': [str(root.id)],
                'protocols': [{'name': 'ssh', 'port': port}],
                'accounts': [{'name': 'admin', 'username': 'admin', 'secret_type': 'password', 'secret': EP,
                              'privileged': True}]}, format='json', **H)
            set_current_org(org)  # (the API request clears the thread's organization)
            assert r.status_code == 201, r.data
            asset = Device.objects.get(id=r.data['id'])
            # account push (role read_only from the platform preset)
            acc = Account.objects.create(asset=asset, name='xpam-push', username='xpam-push', secret_type='password',
                                         secret='Push-pw_1.a')
            push_accounts_to_assets_task([str(acc.id)])
            check(f'{name}: account push creates the account', login(port, 'xpam-push', 'Push-pw_1.a'))
            # discovery
            ex = quickstart_automation_by_snapshot('discover', AutomationTypes.gather_accounts,
                                                   {'assets': [str(asset.id)], 'check_risk': True})
            found = {g.username: g.detail for g in GatheredAccount.objects.filter(asset=asset)}
            check(f'{name}: discovery lists the accounts with their role',
                  found.get('admin', {}).get('role') == 'admin' and found.get('xpam-push', {}).get('role') == 'read_only',
                  found or last_error(ex))
            # change secret
            ex = quickstart_automation_by_snapshot('change', AutomationTypes.change_secret, {
                'accounts': [str(acc.id)], 'assets': [str(asset.id)], 'secret_type': 'password',
                'secret_strategy': 'specific', 'secret': 'Push-pw_2.b', 'check_conn_after_change': True})
            check(f'{name}: change secret sets the new password', login(port, 'xpam-push', 'Push-pw_2.b')
                  and not login(port, 'xpam-push', 'Push-pw_1.a'), last_error(ex))
            # random password (never a "?")
            ex = quickstart_automation_by_snapshot('change-random', AutomationTypes.change_secret, {
                'accounts': [str(acc.id)], 'assets': [str(asset.id)], 'secret_type': 'password',
                'secret_strategy': 'random', 'password_rules': {'length': 24, 'symbol': True}})
            acc = Account.objects.get(id=acc.id)  # (a fresh object: the secret is cached on the instance)
            check(f'{name}: random password works on the device', acc.secret != 'Push-pw_2.b' and '?' not in acc.secret
                  and login(port, 'xpam-push', acc.secret),
                  (repr(acc.secret), last_error(ex)))
            # removal (from the discovered accounts, "Sync deletion")
            ga = GatheredAccount.objects.filter(asset=asset, username='xpam-push').first()
            remove_accounts_task([str(ga.id)])
            check(f'{name}: remove deletes the account from the device', not login(port, 'xpam-push', acc.secret))
            # just-in-time account with a role
            policy = JITPolicy.objects.create(name=f'emu-{name}', org_id=org.id, device_role='operator')
            check(f'{name}: JIT is supported on the device', unsupported_reason(asset, policy) == '',
                  unsupported_reason(asset, policy))
            targets.create_device_account(asset, 'xpam-jit1', 'Jit-pw_1.c', policy)
            ok = login(port, 'xpam-jit1', 'Jit-pw_1.c')
            from libs.ansible.modules_utils.network_device import session
            vendor, _ = targets.device_vendor(asset)
            with session(vendor, 'netemu', port, 'admin', EP, enable_password=EP) as dev:
                role = (dev.user('xpam-jit1') or {}).get('role')
            check(f'{name}: JIT account created with the operator role', ok and role in ('operator', 'read_only'),
                  role)
            try:
                targets.create_device_account(asset, 'admin', 'Other-pw_1.x', policy)
                check(f'{name}: JIT never takes over an existing account', False)
            except targets.TargetError as e:
                check(f'{name}: JIT never takes over an existing account', 'already exists' in str(e), e)
            targets.remove_device_account(asset, 'xpam-jit1', policy)
            check(f'{name}: JIT account removed', not login(port, 'xpam-jit1', 'Jit-pw_1.c'))
            check(f'{name}: the admin account still works', login(port, 'admin', EP))
        except Exception as e:
            traceback.print_exc()
            check(f'{name}: no unexpected error', False, repr(e)[:300])
        finally:
            JITPolicy.objects.filter(name=f'emu-{name}').delete()
            if asset:
                GatheredAccount.objects.filter(asset=asset).delete()
                A.delete(f'/api/v1/assets/devices/{asset.id}/', **H)
                set_current_org(org)
        print(f'   ({time.time() - t0:.0f}s)', flush=True)
print(f'RESULT: {sum(results)}/{len(results)} passed')
