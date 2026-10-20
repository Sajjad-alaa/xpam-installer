"""Isolated stack: the self-service JIT flow end to end — request, instant/approved access, duplicate
requests, extension (same access, counted from the end), end now, automatic close, database expiry."""
import os, sys, time, traceback
sys.path.insert(0, '/opt/jumpserver/apps'); os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'jumpserver.settings')
import django; django.setup()
from django.conf import settings
settings.ALLOWED_HOSTS = list(settings.ALLOWED_HOSTS) + ['testserver']
# no worker in the test stack: the JIT removal task runs inline (eager Celery would close the DB connection)
from accounts.tasks import jit as jit_tasks
_release = lambda jit_id, reason='': __import__('accounts.jit.service', fromlist=['x']).release(
    JITAccount.objects.get(id=jit_id), reason=reason)
jit_tasks.jit_release_task.delay = lambda jit_id, reason='': _release(jit_id, reason)
jit_tasks.jit_release_task.apply_async = lambda args=(), kwargs=None, **kw: _release(*args, **(kwargs or {}))
jit_tasks.jit_provision_task.delay = lambda *a: __import__('accounts.jit.service', fromlist=['x']).provision_granted(*a)
import paramiko, psycopg2
from accounts.models import JITAccount
from django.utils import timezone
from rest_framework.test import APIClient, APIRequestFactory, force_authenticate
from orgs.models import Organization
from orgs.utils import set_current_org, tmp_to_root_org
from assets.models import Platform, Node, Asset
from accounts.models import Account, JITPolicy, JITAccount
from accounts.jit import selfservice, approvals, service
from perms.models import AssetPermission
from tickets.models import ApplyAssetTicket
from users.models import User

ROOT_PW, TPW = os.environ['ROOT_PASSWORD'], os.environ['TARGET_PG_PASSWORD']
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


class Req:  # what selfservice.submit needs from a request
    def __init__(self, user):
        self.user = user


def err(fn, *a, **kw):
    try:
        fn(*a, **kw)
        return ''
    except (selfservice.SelfServiceError, approvals.ApprovalError) as e:
        return str(e)


org = Organization.default()
set_current_org(org)
admin = User.objects.get(username='admin')
user = User.objects.filter(username='flow.user').first() or User.objects.create(
    username='flow.user', name='Flow User', email='flow.user@example.invalid', is_first_login=False)
org.add_member(user)
A = APIClient(); A.force_authenticate(admin)
U = APIClient(); U.force_authenticate(user)
root = Node.org_root()
R = Req(user)


def api_asset(path, data):
    r = A.post(path, data, format='json', HTTP_X_JMS_ORG=str(org.id))
    set_current_org(org)
    assert r.status_code == 201, r.data
    return Asset.objects.get(id=r.data['id'])


def rule(name, asset, **kw):
    p = JITPolicy.objects.create(name=name, org_id=org.id, scope='all', priority=5, self_service=True,
                                 jit_only=True, require_reason=True, **kw)
    p.users = {'type': 'ids', 'ids': [str(user.id)]}
    p.assets = {'type': 'ids', 'ids': [str(asset.id)]}
    p.save()
    return p


def grant_of(ticket):
    with tmp_to_root_org():
        return AssetPermission.objects.filter(id=ticket.id).first()


def connect_jit(asset):
    r = U.post('/api/v1/authentication/connection-token/', {
        'asset': str(asset.id), 'account': '@JIT', 'protocol': 'ssh', 'connect_method': 'web_cli',
        'input_username': '', 'input_secret': ''}, format='json', HTTP_X_JMS_ORG=str(org.id))
    set_current_org(org)
    return r


def cleanup():
    with tmp_to_root_org():
        for j in JITAccount.objects.exclude(status='removed'):
            service.release(j, reason='cleanup')
        for t in ApplyAssetTicket.objects.filter(applicant=user, status='open'):
            t.close()
        AssetPermission.objects.filter(users=user).delete()
        JITPolicy.objects.filter(name__startswith='flow-').delete()
        for a in Asset.objects.filter(name__startswith='flow-'):
            A.delete(f'/api/v1/assets/assets/{a.id}/', HTTP_X_JMS_ORG=str(org.id))
    set_current_org(org)


cleanup()
try:
    # ================================================================ Linux host, instant access
    host = api_asset('/api/v1/assets/hosts/', {
        'name': 'flow-linux', 'address': 'flowhost', 'platform': Platform.objects.get(name='Linux').id,
        'nodes': [str(root.id)], 'protocols': [{'name': 'ssh', 'port': 22}],
        'accounts': [{'name': 'root', 'username': 'root', 'secret_type': 'password', 'secret': ROOT_PW,
                      'privileged': True}]})
    pol = rule('flow-instant', host, auto_approve=True, auto_approve_max_hours=2, max_hours=2)
    check('the asset is requestable', [a.name for a, p in selfservice.requestable_assets(user)] == ['flow-linux'])
    check('a reason is required', 'reason' in err(selfservice.submit, R, [host.id], 1).lower())
    t1 = selfservice.submit(R, [host.id], 1.5, reason='deploy hotfix')
    g = grant_of(t1)
    check('instant: approved by the rule, access granted', t1.state == 'approved' and g is not None, t1.state)
    e = err(selfservice.submit, R, [host.id], 1, reason='again')
    check('a second request for the same assets is refused (extend instead)', 'already have access' in e, e)

    r = connect_jit(host)
    jit = JITAccount.objects.filter(user=user, asset=host, status='ready').first()
    acc = Account.objects.get(id=jit.account_id) if jit else None
    check('connecting creates the JIT account on the server', r.status_code == 201 and jit and ssh_ok(jit.username, acc.secret),
          r.data if r.status_code != 201 else jit.username)

    # extension: 1.5 h left of a 2 h maximum, +1 h was refused before (counted from now)
    before = g.date_expired
    t2 = selfservice.extend(R, g.id, 1)
    g.refresh_from_db()
    with tmp_to_root_org():
        grants = AssetPermission.objects.filter(users=user, from_ticket=True).count()
    check('extension of 1 h is accepted although 1.5 h are left (counted from the end)', t2.state == 'approved', t2.state)
    check('the same access lasts 1 h longer (no second access)',
          abs((g.date_expired - before).total_seconds() - 3600) < 5 and grants == 1, (g.date_expired - before, grants))
    check("the extension keeps the original reason", 'deploy hotfix' in (t2.comment or ''), t2.comment)
    check('the JIT account is still there after the extension',
          JITAccount.objects.filter(id=jit.id, status='ready').exists())
    e = err(selfservice.extend, R, g.id, 3)
    check('an extension longer than the rule allows is refused', 'at most 2' in e, e)

    selfservice.end_now(user, g.id)
    g.refresh_from_db()
    check('end now: the access ends', g.date_expired <= timezone.now())
    time.sleep(2)
    check('end now: the JIT account is removed from the server',
          not JITAccount.objects.filter(id=jit.id, status='ready').exists() and not ssh_ok(jit.username, acc.secret))

    # ================================================================ approval required
    pol.auto_approve = False; pol.save()
    t3 = selfservice.submit(R, [host.id], 1, reason='maintenance')
    check('approval rule: the request waits', t3.status == 'open')
    e = err(selfservice.submit, R, [host.id], 1, reason='maintenance')
    check('a duplicate waiting request is refused', 'already waiting' in e, e)
    e = err(approvals.decide, user, t3.id, 'approve')
    check('the requester cannot approve it', 'own request' in e, e)
    inbox = approvals.pending_for(admin)
    check("the approver's inbox shows it with the reason", any(i['id'] == str(t3.id) and i['reason'] == 'maintenance'
                                                               for i in inbox), inbox)
    approvals.decide(admin, t3.id, 'approve')
    g3 = grant_of(t3)
    check('approved: access granted', g3 is not None)
    t4 = selfservice.extend(R, g3.id, 1, reason='need more time')
    mine = selfservice.my_access(user)
    check('the waiting extension is linked to the access', t4.status == 'open' and
          any(p['extends'] == str(g3.id) for p in mine['pending']), mine['pending'])
    e = err(selfservice.extend, R, g3.id, 1)
    check('a second extension while one waits is refused', 'already waiting' in e, e)
    end_before = g3.date_expired
    approvals.decide(admin, t4.id, 'approve')
    g3.refresh_from_db()
    with tmp_to_root_org():
        grants = AssetPermission.objects.filter(users=user, from_ticket=True, date_expired__gt=timezone.now()).count()
    check('approved extension: the same access lasts longer',
          abs((g3.date_expired - end_before).total_seconds() - 3600) < 5 and grants == 1,
          (g3.date_expired - end_before, grants))
    t5 = selfservice.extend(R, g3.id, 1, reason='once more')
    selfservice.end_now(user, g3.id)
    t5.refresh_from_db()
    check('end now cancels the waiting extension', t5.status == 'closed', t5.status)

    # rejected request: the note reaches the requester
    t6 = selfservice.submit(R, [host.id], 1, reason='curious')
    check('rejecting needs a reason', 'why' in err(approvals.decide, admin, t6.id, 'reject').lower())
    approvals.decide(admin, t6.id, 'reject', 'not needed')
    recent = selfservice.my_access(user)['recent']
    check('the requester sees the rejection and why',
          any(r['id'] == str(t6.id) and r['state'] == 'rejected' and r['note']['text'] == 'not needed' for r in recent), recent)

    # nobody decided in time: closed automatically, the requester sees why
    t7 = selfservice.submit(R, [host.id], 1, reason='late')
    ApplyAssetTicket.objects.filter(id=t7.id).update(date_created=timezone.now() - timezone.timedelta(days=3))
    from tickets import sla
    sla.run()
    t7.refresh_from_db()
    note = next((r['note'] for r in selfservice.my_access(user)['recent'] if r['id'] == str(t7.id)), None)
    check('an undecided request is closed automatically and the requester is told why',
          t7.status == 'closed' and note and note['by'] == 'XPAM' and 'automatically' in note['text'], note)
    cleanup()

    # ================================================================ PostgreSQL: the login expiry follows an extension
    db = api_asset('/api/v1/assets/databases/', {
        'name': 'flow-pg', 'address': 'flowpg', 'platform': Platform.objects.get(name='PostgreSQL').id,
        'nodes': [str(root.id)], 'protocols': [{'name': 'postgresql', 'port': 5432}], 'db_name': 'postgres',
        'accounts': [{'name': 'postgres', 'username': 'postgres', 'secret_type': 'password', 'secret': TPW,
                      'privileged': True}]})
    rule('flow-db', db, auto_approve=True, auto_approve_max_hours=4, max_hours=4, mode='approved_window',
         db_privilege='read_only')
    t8 = selfservice.submit(R, [db.id], 1, reason='report')
    g8 = grant_of(t8)
    service.reconcile()
    jit = JITAccount.objects.filter(user=user, asset=db, status='ready').first()

    def valid_until(name):
        c = psycopg2.connect(host='flowpg', user='postgres', password=TPW, dbname='postgres'); c.autocommit = True
        cur = c.cursor(); cur.execute('SELECT rolvaliduntil FROM pg_roles WHERE rolname = %s', (name,))
        row = cur.fetchone(); c.close()
        return row[0] if row else None
    v1 = valid_until(jit.username) if jit else None
    check('approved window: the database login is created with an expiry', jit and v1, (jit and jit.username, v1))
    selfservice.extend(R, g8.id, 2, reason='report takes longer')
    service.reconcile()
    v2 = valid_until(jit.username) if jit else None
    check('extension: the database login expiry moves 2 h later', v1 and v2 and abs((v2 - v1).total_seconds() - 7200) < 5,
          (v1, v2))
except Exception as e:
    traceback.print_exc()
    check('no unexpected error', False, repr(e)[:300])
finally:
    try:
        cleanup()
    except Exception:
        traceback.print_exc()
print(f'RESULT: {sum(results)}/{len(results)} passed')
