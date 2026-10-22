"""Isolated stack (core container + throwaway DB + emulator + browser service on one network): FortiGate / PAN-OS web admin in the Remote browser (core token -> browser service ->
emulator login page), with the stored account, a wrong password, certificate checking and a JIT account.
The browser request is built exactly like Lion builds it (pkg/lion/session/xpambrowser.go)."""
import json, os, secrets, ssl, sys, time, traceback, urllib.request
from urllib.parse import urlsplit
sys.path.insert(0, '/opt/jumpserver/apps'); os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'jumpserver.settings')
import django; django.setup()
from django.conf import settings
settings.ALLOWED_HOSTS = list(settings.ALLOWED_HOSTS) + ['testserver']
from django.utils import timezone
from rest_framework.test import APIClient
from orgs.models import Organization
from orgs.utils import set_current_org, tmp_to_root_org
from assets.models import Platform, Node, Asset, PlatformProtocol
from accounts.models import JITPolicy, JITAccount
from accounts.jit import service
from authentication.models import ConnectionToken
from authentication.serializers.connect_token_secret import ConnectionTokenSecretSerializer
from perms.models import AssetPermission
from terminal.connect_methods import ConnectMethodUtil
from users.models import User

EP, KEY = os.environ['EMU_PASSWORD'], os.environ['BROWSER_KEY']
results = []
NOVERIFY = ssl._create_unverified_context()


def check(name, ok, detail=''):
    results.append(bool(ok))
    print(('PASS ' if ok else 'FAIL ') + name + (f'  [{str(detail)[:300]}]' if detail != '' else ''), flush=True)


def logins(port):
    with urllib.request.urlopen(f'https://netemu:{port}/_emu/logins', context=NOVERIFY, timeout=5) as r:
        return json.loads(r.read())


def lion_body(data, password=None):
    a, spec, acc = data['asset'], data['asset']['spec_info'], data['account']
    raw = a['address'].strip()
    proto = (data['protocol'] or '').lower()
    if '://' not in raw:
        raw = ('https' if proto == 'https' else 'http') + '://' + raw
    u = urlsplit(raw)
    host = u.netloc
    if u.port is None:
        for p in a['protocols']:
            if p['name'] in ('http', 'https') and p['port'] > 0 and not (
                    (u.scheme == 'http' and p['port'] == 80) or (u.scheme == 'https' and p['port'] == 443)):
                host = f'{u.hostname if ":" not in u.hostname else "[" + u.hostname + "]"}:{p["port"]}'
                break
    url = f'{u.scheme}://{host}{u.path}' + (f'?{u.query}' if u.query else '')
    return {'url': url, 'width': 1280, 'height': 800, 'username': acc['username'],
            'password': acc['secret'] if password is None else password, 'autofill': spec.get('autofill'),
            'username_selector': spec.get('username_selector'), 'password_selector': spec.get('password_selector'),
            'submit_selector': spec.get('submit_selector'), 'success_selector': spec.get('success_selector'),
            'interactive_selector': spec.get('interactive_selector'), 'script': spec.get('script'),
            'allowed_urls': spec.get('allowed_urls'), 'ignore_cert': not spec.get('verify_cert')}


def browser(path, body):
    req = urllib.request.Request('http://browser:9001' + path, json.dumps(body).encode(),
                                 {'Content-Type': 'application/json', 'Authorization': 'Bearer ' + KEY})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read() or b'{}')


def browse_and_wait(body, port, user, seconds=40):
    """Start a browser session; True when the emulator saw `user` sign in on its web page."""
    before = len(logins(port))
    sess = browser('/sessions', body)
    try:
        end = time.time() + seconds
        while time.time() < end:
            new = logins(port)[before:]
            hit = [x for x in new if x['user'] == user]
            if hit:
                return hit[0]
            time.sleep(1)
        return None
    finally:
        try:
            browser(f'/sessions/{sess["container_id"]}/release', {})
        except Exception:
            pass


def token_data(asset, account, client=None):
    if account != '@JIT':
        from accounts.models import Account
        account = str(Account.objects.get(asset=asset, username=account).id)
    r = (client or A).post('/api/v1/authentication/connection-token/', {
        'asset': str(asset.id), 'account': account, 'protocol': 'http', 'connect_method': 'web_browser',
        'input_username': '', 'input_secret': ''}, format='json', HTTP_X_JMS_ORG=str(org.id))
    set_current_org(org)
    assert r.status_code == 201, r.data
    with tmp_to_root_org():
        tok = ConnectionToken.objects.get(id=r.data['id'])
    return ConnectionTokenSecretSerializer(tok).data


org = Organization.default()
set_current_org(org)
admin = User.objects.get(username='admin')
A = APIClient(); A.force_authenticate(admin)
root = Node.org_root()
tu = User.objects.filter(username='gui.tester').first() or User.objects.create(
    username='gui.tester', name='gui.tester', email='gui.tester@example.invalid', is_first_login=False)
org.add_member(tu)
T = APIClient(); T.force_authenticate(tu)

# ---- platforms
for name, sel in (('FortiGate', 'id=secretkey'), ('PaloAlto', 'id=passwd')):
    pp = PlatformProtocol.objects.filter(platform__name=name, name='http').first()
    check(f'{name} platform has the web admin protocol', pp and pp.port == 443 and pp.setting.get('password_selector') == sel,
          pp and pp.setting)
    check(f'{name}: the web admin port is editable on the asset', pp and pp.port_from_addr is False)
web_pp = PlatformProtocol.objects.filter(platform__name='Website', name='http').first()
check('websites still take the port from the address', web_pp is None or web_pp.port_from_addr is True)
methods = ConnectMethodUtil.get_protocols_connect_methods('windows')
check('"Remote browser" is offered for the http protocol', 'web_browser' in [m['value'] for m in methods.get('http', [])])

CASES = [('FortiGate', 2201, 4431), ('PaloAlto', 2202, 4432)]
for name, ssh_port, gui_port in CASES:
    print(f'== {name}', flush=True)
    asset = None
    try:
        r = A.post('/api/v1/assets/devices/', {
            'name': f'gui-{name}', 'address': 'netemu', 'platform': Platform.objects.get(name=name).id,
            'nodes': [str(root.id)],
            'protocols': [{'name': 'ssh', 'port': ssh_port}, {'name': 'http', 'port': gui_port}],
            'accounts': [{'name': 'admin', 'username': 'admin', 'secret_type': 'password', 'secret': EP,
                          'privileged': True}]}, format='json', HTTP_X_JMS_ORG=str(org.id))
        set_current_org(org)
        assert r.status_code == 201, r.data
        asset = Asset.objects.get(id=r.data['id'])
        perm = AssetPermission.objects.create(name=f'gui-{name}', org_id=org.id,
                                              date_expired=timezone.now() + timezone.timedelta(days=1))
        perm.users.add(admin, tu); perm.assets.add(asset); perm.accounts = ['@ALL', '@JIT']; perm.save()

        data = token_data(asset, 'admin')
        spec = data['asset']['spec_info']
        check(f'{name}: token addresses the web admin page over https', data['asset']['address'] == 'https://netemu',
              data['asset']['address'])
        check(f'{name}: token carries the platform login fields', spec.get('password_selector') and spec.get('autofill') == 'basic'
              and spec.get('verify_cert') is False, spec)
        body = lion_body(data)
        check(f'{name}: browser URL includes the admin port', body['url'] == f'https://netemu:{gui_port}', body['url'])
        hit = browse_and_wait(body, gui_port, 'admin')
        check(f'{name}: Remote browser signs in to the web admin with the stored account', hit, hit)

        miss = browse_and_wait(lion_body(token_data(asset, 'admin'), password=secrets.token_urlsafe(12)), gui_port, 'admin', 30)
        check(f'{name}: a wrong password does not sign in', not miss, miss)

        pp = PlatformProtocol.objects.get(platform__name=name, name='http')
        pp.setting = {**pp.setting, 'verify_cert': True}; pp.save()
        data = token_data(asset, 'admin')
        check(f'{name}: "Verify certificate" on the platform reaches the browser', lion_body(data)['ignore_cert'] is False)
        miss = browse_and_wait(lion_body(data), gui_port, 'admin', 25)
        check(f'{name}: a self-signed device is refused when the certificate is checked', not miss, miss)
        pp.setting = {**pp.setting, 'verify_cert': False}; pp.save()

        policy = JITPolicy.objects.create(name=f'gui-{name}', org_id=org.id, scope='all', priority=5,
                                          device_role='read_only')
        policy.users = {'type': 'ids', 'ids': [str(tu.id)]}
        policy.assets = {'type': 'ids', 'ids': [str(asset.id)]}
        policy.save()
        data = token_data(asset, '@JIT', T)
        jit_user = data['account']['username']
        check(f'{name}: JIT account created for the web session', jit_user and jit_user != 'admin', jit_user)
        hit = browse_and_wait(lion_body(data), gui_port, jit_user)
        check(f'{name}: Remote browser signs in with the JIT account (read-only role)',
              hit and hit['role'] in ('read_only', 'xpam_read_only', 'superreader'), hit)
        with tmp_to_root_org():
            for j in JITAccount.objects.filter(asset_id=asset.id).exclude(status='removed'):
                service.release(j, reason='test')
        miss = browse_and_wait(lion_body(data), gui_port, jit_user, 25)
        check(f'{name}: the released JIT account can no longer sign in', not miss, miss)
    except Exception as e:
        traceback.print_exc()
        check(f'{name}: no unexpected error', False, repr(e)[:300])
    finally:
        with tmp_to_root_org():
            JITPolicy.objects.filter(name__startswith='gui-').delete()
            AssetPermission.objects.filter(name__startswith='gui-').delete()
        if asset:
            A.delete(f'/api/v1/assets/assets/{asset.id}/', HTTP_X_JMS_ORG=str(org.id))
            set_current_org(org)
print(f'RESULT: {sum(results)}/{len(results)} passed')
