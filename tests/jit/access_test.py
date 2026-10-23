"""Isolated stack: what an access request allows and the access shown on its ticket (5.1.18) — the rule's allowed
protocols and actions, the request choosing among them, the granted access enforcing them; the ticket's access
(state, accounts, sessions), the list's Access column, the requester ending it and an approver revoking it."""
import os, sys, time, traceback
sys.path.insert(0, '/opt/jumpserver/apps'); os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'jumpserver.settings')
import django; django.setup()
from django.conf import settings
settings.ALLOWED_HOSTS = list(settings.ALLOWED_HOSTS) + ['testserver']
# no worker in the test stack: the JIT tasks run inline (eager Celery would close the DB connection)
from accounts.tasks import jit as jit_tasks
_release = lambda jit_id, reason='': __import__('accounts.jit.service', fromlist=['x']).release(
    JITAccount.objects.get(id=jit_id), reason=reason)
jit_tasks.jit_release_task.delay = lambda jit_id, reason='': _release(jit_id, reason)
jit_tasks.jit_release_task.apply_async = lambda args=(), kwargs=None, **kw: _release(*args, **(kwargs or {}))
jit_tasks.jit_provision_task.delay = lambda *a: __import__('accounts.jit.service', fromlist=['x']).provision_granted(*a)
import xpack.utils
xpack.utils.has_ticket_license = lambda: True  # (the ticket API needs a licence with tickets)
xpack.utils.get_license_user_limit = lambda: 10  # (the test needs a third user; the trial allows 2)
import paramiko
from rest_framework.test import APIClient
from orgs.models import Organization
from orgs.utils import set_current_org, tmp_to_root_org
from assets.models import Platform, Node, Asset
from accounts.models import Account, JITPolicy, JITAccount
from accounts.jit import selfservice, service
from perms.const import ActionChoices
from perms.models import AssetPermission
from tickets.models import ApplyAssetTicket, Comment
from users.models import User

ROOT_PW = os.environ['ROOT_PASSWORD']
results = []


def check(name, ok, detail=''):
    results.append(bool(ok))
    print(('PASS ' if ok else 'FAIL ') + name + (f'  [{str(detail)[:240]}]' if detail != '' else ''), flush=True)


def ssh_ok(user, pw):
    c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        c.connect('flowhost', 22, username=user, password=pw, timeout=10, look_for_keys=False, allow_agent=False)
        return True
    except Exception:
        return False
    finally:
        c.close()


class Req:
    def __init__(self, user):
        self.user = user


def err(fn, *a, **kw):
    try:
        fn(*a, **kw)
        return ''
    except selfservice.SelfServiceError as e:
        return str(e)


org = Organization.default()
set_current_org(org)
admin = User.objects.get(username='admin')
user = User.objects.filter(username='acc.user').first() or User.objects.create(
    username='acc.user', name='Access User', email='acc.user@example.invalid', is_first_login=False)
other = User.objects.filter(username='acc.other').first() or User.objects.create(
    username='acc.other', name='Other User', email='acc.other@example.invalid', is_first_login=False)
for u in (user, other):
    org.add_member(u)
A = APIClient(); A.force_authenticate(admin)
U = APIClient(); U.force_authenticate(user)
O = APIClient(); O.force_authenticate(other)
H = {'HTTP_X_JMS_ORG': str(org.id)}
root = Node.org_root()
R = Req(user)


def access(client, ticket):
    r = client.get(f'/api/v1/tickets/apply-asset-tickets/{ticket.id}/access/', **H)
    set_current_org(org)
    return r


def connect(asset, protocol):
    r = U.post('/api/v1/authentication/connection-token/', {
        'asset': str(asset.id), 'account': '@JIT', 'protocol': protocol, 'connect_method': 'web_cli',
        'input_username': '', 'input_secret': ''}, format='json', **H)
    set_current_org(org)
    return r


def cleanup():
    with tmp_to_root_org():
        for j in JITAccount.objects.exclude(status='removed'):
            service.release(j, reason='cleanup')
        for t in ApplyAssetTicket.objects.filter(applicant=user, status='open'):
            t.close()
        AssetPermission.objects.filter(users=user).delete()
        JITPolicy.objects.filter(name__startswith='acc-').delete()
        for a in Asset.objects.filter(name__startswith='acc-'):
            A.delete(f'/api/v1/assets/assets/{a.id}/', **H)
    set_current_org(org)


cleanup()
try:
    r = A.post('/api/v1/assets/hosts/', {
        'name': 'acc-linux', 'address': 'flowhost', 'platform': Platform.objects.get(name='Linux').id,
        'nodes': [str(root.id)], 'protocols': [{'name': 'ssh', 'port': 22}, {'name': 'sftp', 'port': 22}],
        'accounts': [{'name': 'root', 'username': 'root', 'secret_type': 'password', 'secret': ROOT_PW,
                      'privileged': True}]}, format='json', **H)
    set_current_org(org)
    host = Asset.objects.get(id=r.data['id'])

    # ================================================================ the rule: SSH only, connect + download
    r = A.post('/api/v1/accounts/jit-policies/', {
        'name': 'acc-ssh-only', 'scope': 'all', 'priority': 5, 'self_service': True, 'jit_only': True,
        'require_reason': False, 'auto_approve': True, 'auto_approve_max_hours': 2, 'max_hours': 2,
        'users': {'type': 'ids', 'ids': [str(user.id)]}, 'assets': {'type': 'ids', 'ids': [str(host.id)]},
        'protocols': ['ssh'], 'actions': ['download']}, format='json', **H)
    set_current_org(org)
    check('a rule is saved with allowed protocols and actions', r.status_code == 201, r.data)
    pol = JITPolicy.objects.get(name='acc-ssh-only')
    check('the rule always lets one connect (connect added to the actions)',
          pol.protocols == ['ssh'] and pol.actions == ActionChoices.connect | ActionChoices.download,
          (pol.protocols, pol.actions))
    r = U.get('/api/v1/accounts/jit-access/requestable/', **H)
    set_current_org(org)
    opts = next((a['options'] for a in r.data if a['name'] == 'acc-linux'), None)
    check('the request form offers what the rule allows (the asset has SSH and SFTP; the rule SSH)',
          opts == {'protocols': ['ssh'], 'actions': ['connect', 'download']}, opts)

    e = err(selfservice.submit, R, [host.id], 1, protocols=['sftp'])
    check('a protocol the rule does not allow is refused', 'ssh' in e, e)
    e = err(selfservice.submit, R, [host.id], 1, actions=['connect', 'upload'])
    check('an action the rule does not allow is refused', 'upload' in e, e)
    t1 = selfservice.submit(R, [host.id], 1)
    with tmp_to_root_org():
        t1 = ApplyAssetTicket.objects.get(id=t1.id)
        perm = AssetPermission.objects.filter(id=t1.id).first()
    check('nothing chosen: the request asks for what the rule allows (SSH; connect, download)',
          t1.apply_protocols == ['ssh'] and t1.apply_actions == ActionChoices.connect | ActionChoices.download,
          (t1.apply_protocols, t1.apply_actions))
    check('the approved access carries them (protocols, actions)',
          perm is not None and perm.protocols == ['ssh'] and perm.actions == ActionChoices.connect | ActionChoices.download,
          perm and (perm.protocols, perm.actions))

    r = connect(host, 'ssh')
    jit = JITAccount.objects.filter(user=user, asset=host, status='ready').first()
    acc = Account.objects.get(id=jit.account_id) if jit else None
    check('connecting with SSH works (the JIT account is created)', r.status_code == 201 and jit and ssh_ok(jit.username, acc.secret),
          r.data if r.status_code != 201 else jit.username)
    r = connect(host, 'sftp')
    check('connecting with another protocol (SFTP) is refused', r.status_code >= 400, (r.status_code, str(r.data)[:160]))

    # ================================================================ the access on the ticket
    r = access(U, t1)
    d = r.data
    check('the requester sees the access on the ticket: active, time left, protocols, actions',
          r.status_code == 200 and d['state'] == 'active' and d['seconds_left'] > 3000 and d['protocols'] == ['ssh']
          and d['actions'] == ['connect', 'download'], d)
    check('... its assets and its just-in-time account',
          [a['name'] for a in d['assets']] == ['acc-linux'] and [a['username'] for a in d['accounts']] == [jit.username], d)
    check('... the requester can end or extend it, not revoke it', d['can'] == {'end': True, 'extend': True, 'revoke': False}, d['can'])
    r = access(A, t1)
    check('an administrator can revoke it', r.status_code == 200 and r.data['can']['revoke'] is True, r.data.get('can'))
    r = access(O, t1)
    check("another user does not see someone else's request", r.status_code == 404, r.status_code)
    r = U.get('/api/v1/tickets/tickets/?limit=20', **H)
    set_current_org(org)
    row = next((x for x in r.data['results'] if x['id'] == str(t1.id)), None)
    check('the ticket list shows the access: active, until when', row and row['access_state'] and row['access_state']['state'] == 'active', row and row.get('access_state'))
    r = U.post(f'/api/v1/tickets/apply-asset-tickets/{t1.id}/access/revoke/', {'reason': 'x'}, format='json', **H)
    set_current_org(org)
    check('the requester cannot revoke (only end)', r.status_code == 400 and 'approver' in str(r.data), (r.status_code, r.data))

    # ================================================================ an administrator revokes it
    r = A.post(f'/api/v1/tickets/apply-asset-tickets/{t1.id}/access/revoke/', {'reason': 'incident 4711'}, format='json', **H)
    set_current_org(org)
    check('an administrator revokes the access', r.status_code == 200 and 'sessions_ended' in r.data, (r.status_code, r.data))
    with tmp_to_root_org():
        perm = AssetPermission.objects.get(id=t1.id)
        jit.refresh_from_db()
        note = Comment.objects.filter(ticket_id=t1.id, body__icontains='revoked').values_list('body', flat=True).first()
    check('it ends now', perm.date_expired <= __import__('django.utils.timezone', fromlist=['x']).now(), perm.date_expired)
    check('its just-in-time account is removed from the server', jit.status == 'removed' and not ssh_ok(jit.username, acc.secret), jit.status)
    check('the reason is noted on the request', note and 'incident 4711' in note and 'admin' in note.lower(), note)
    d = access(U, t1).data
    check('the ticket shows it ended early, with nothing left to do', d['state'] == 'ended' and d['can'] == {'end': False, 'extend': False, 'revoke': False}, d)
    r = A.post(f'/api/v1/tickets/apply-asset-tickets/{t1.id}/access/revoke/', {}, format='json', **H)
    set_current_org(org)
    check('revoking again is refused (not active)', r.status_code == 400, r.data)
    r = connect(host, 'ssh')
    check('connecting after the revocation is refused', r.status_code >= 400, (r.status_code, str(r.data)[:120]))

    # ================================================================ the requester ends a new access
    t2 = selfservice.submit(R, [host.id], 1, protocols=['ssh'], actions=['connect'])
    with tmp_to_root_org():
        t2 = ApplyAssetTicket.objects.get(id=t2.id)
    check('a request with explicit choices keeps them (SSH; connect only)',
          t2.apply_protocols == ['ssh'] and t2.apply_actions == ActionChoices.connect, (t2.apply_protocols, t2.apply_actions))
    t2_ext = selfservice.extend(R, t2.id, 0.5)
    with tmp_to_root_org():
        t2_ext = ApplyAssetTicket.objects.get(id=t2_ext.id)
    check('an extension keeps the original protocols and actions',
          t2_ext.apply_protocols == ['ssh'] and t2_ext.apply_actions == ActionChoices.connect,
          (t2_ext.apply_protocols, t2_ext.apply_actions))
    r = U.post(f'/api/v1/tickets/apply-asset-tickets/{t2.id}/access/end/', {}, format='json', **H)
    set_current_org(org)
    check('the requester ends it from the ticket', r.status_code == 200 and access(U, t2).data['state'] == 'ended', r.data)

    # ================================================================ a console request: protocols 'all'
    from tickets.serializers import ApplyAssetSerializer
    from tickets.models import TicketFlow
    flow = TicketFlow.get_org_related_flows(org_id=org.id).filter(type='apply_asset').first()
    s = ApplyAssetSerializer(data={'title': 'acc console', 'type': 'apply_asset', 'org_id': str(org.id), 'flow_id': str(flow.id),
                                   'apply_assets': [str(host.id)], 'apply_nodes': [], 'apply_accounts': ['@ALL'],
                                   'apply_actions': ['all'], 'apply_protocols': ['all', 'SSH'],
                                   'apply_date_start': '2026-10-01T00:00:00Z', 'apply_date_expired': '2026-10-02T00:00:00Z'},
                             context={'request': Req(user)})
    check("a console request asking for 'all' protocols stores none (= every protocol)", s.is_valid() and s.validated_data['apply_protocols'] == [], s.errors)
finally:
    cleanup()

print(f'RESULT: {sum(results)}/{len(results)} passed')
