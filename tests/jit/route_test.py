"""Isolated stack: who approves a just-in-time request and why it is not approved at once (5.1.19) — the rule's
"Approved by" (an approval flow of Tickets → Flow setup, or specific people), the preview before sending
(Workspace and console), the note on a request that waits ("Not approved automatically: ... Approval: level 1 ..."),
the approvers' inbox flag, and requests from the console's form going through the same decision."""
import os, sys, traceback
sys.path.insert(0, '/opt/jumpserver/apps'); os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'jumpserver.settings')
import django; django.setup()
from django.conf import settings
from django.utils import timezone
settings.ALLOWED_HOSTS = list(settings.ALLOWED_HOSTS) + ['testserver']
from accounts.tasks import jit as jit_tasks
jit_tasks.jit_provision_task.delay = lambda *a: None  # (no target servers here: the accounts are not created)
jit_tasks.jit_release_task.delay = lambda *a, **k: None
jit_tasks.jit_release_task.apply_async = lambda *a, **k: None
import xpack.utils
xpack.utils.has_ticket_license = lambda: True
xpack.utils.get_license_user_limit = lambda: 20
xpack.utils.get_license_asset_count = lambda: 50  # (the trial allows one asset; the test needs a few)
from rest_framework.test import APIClient
from orgs.models import Organization
from orgs.utils import set_current_org, tmp_to_root_org
from assets.models import Platform, Node, Asset
from accounts.models import JITPolicy
from accounts.jit import selfservice, approvals
from tickets.models import ApplyAssetTicket, Comment, TicketFlow
from users.models import User

results = []


def check(name, ok, detail=''):
    results.append(bool(ok))
    print(('PASS ' if ok else 'FAIL ') + name + (f'  [{str(detail)[:300]}]' if detail != '' else ''), flush=True)


class Req:
    def __init__(self, user):
        self.user = user


org = Organization.default(); set_current_org(org)
admin = User.objects.get(username='admin')


def mkuser(name):
    u = User.objects.filter(username=name).first() or User.objects.create(
        username=name, name=name.replace('.', ' ').title(), email=f'{name}@example.invalid', is_first_login=False)
    org.add_member(u)
    return u


user, dba1, dba2, lead = mkuser('rt.user'), mkuser('rt.dba1'), mkuser('rt.dba2'), mkuser('rt.lead')
A = APIClient(); A.force_authenticate(admin)
U = APIClient(); U.force_authenticate(user)
H = {'HTTP_X_JMS_ORG': str(org.id)}


def api(client, method, url, data=None):
    r = getattr(client, method)(url, data, format='json', **H)
    set_current_org(org)
    return r


def host(name):
    r = api(A, 'post', '/api/v1/assets/hosts/', {
        'name': name, 'address': f'10.9.9.{Asset.objects.count() + 10}', 'platform': Platform.objects.get(name='Linux').id,
        'nodes': [str(Node.org_root().id)], 'protocols': [{'name': 'ssh', 'port': 22}]})
    assert r.status_code == 201, r.data
    return Asset.objects.get(id=r.data['id'])


def rule(name, asset, **kw):
    data = {'name': name, 'scope': 'all', 'priority': 5, 'self_service': True, 'jit_only': True,
            'require_reason': False, 'max_hours': 200, 'users': {'type': 'ids', 'ids': [str(user.id)]},
            'assets': {'type': 'ids', 'ids': [str(asset.id)]}}
    data.update(kw)
    return api(A, 'post', '/api/v1/accounts/jit-policies/', data)


def notes(ticket):
    return ' | '.join(Comment.objects.filter(ticket=ticket, user__isnull=True).values_list('body', flat=True))


def steps(ticket):
    return [sorted(s.ticket_assignees.values_list('assignee__username', flat=True))
            for s in ticket.ticket_steps.order_by('level')]


def reset():
    # (the user's accesses from earlier steps would make a new request pointless)
    from perms.models import AssetPermission
    with tmp_to_root_org():
        AssetPermission.objects.filter(from_ticket=True, users=user).delete()
    set_current_org(org)


def cleanup():
    with tmp_to_root_org():
        for t in ApplyAssetTicket.objects.filter(applicant=user, status='open'):
            t.close()
        JITPolicy.objects.filter(name__startswith='rt-').delete()
    reset()
    with tmp_to_root_org():
        TicketFlow.objects.filter(name__startswith='rt-').delete()
        for a in Asset.objects.filter(name__startswith='rt-'):
            api(A, 'delete', f'/api/v1/assets/assets/{a.id}/')
    set_current_org(org)


cleanup()
try:
    # ================================================================ instant up to 2 h, then the organization's flow
    web = host('rt-web')
    r = rule('rt-web-2h', web, auto_approve=True, auto_approve_max_hours=2)
    check('a rule: instant up to 2 h, else "An approval flow" (the default)',
          r.status_code == 201 and r.data['approval_route']['value'] == 'flow' and r.data['approval_flow'] is None, r.data)
    p = api(U, 'post', '/api/v1/accounts/jit-access/preview/', {'assets': [str(web.id)], 'hours': 1}).data
    check('preview, 1 h: approved at once', p['instant'] is True and p['rules'] == ['rt-web-2h'], p)
    p = api(U, 'post', '/api/v1/accounts/jit-access/preview/', {'assets': [str(web.id)], 'hours': 168}).data
    check('preview, 168 h: needs approval, says why (the 2 h limit) and who (level 1)',
          p['instant'] is False and '168' in p['why'] and '2 h' in p['why'] and p['route'] and p['route'][0]['level'] == 1, p)
    t = selfservice.submit(Req(user), [web.id], 1)
    check('1 h: approved at once', t.state == 'approved', t.state)
    reset()
    t = selfservice.submit(Req(user), [web.id], 168)
    check('168 h: waits for approval', t.state == 'pending' and t.status == 'open', t.state)
    n = notes(t)
    check('the request says why it is not instant and who approves',
          'Not approved automatically' in n and '168' in n and 'Approval: level 1' in n, n)
    inbox = [i for i in approvals.pending_for(admin) if i['id'] == str(t.id)]
    flag = [f['text'] for f in (inbox[0]['flags'] if inbox else []) if f['key'] == 'not_auto']
    check("the approver's inbox shows why it was not instant", flag and '2 h' in flag[0], inbox[0]['flags'] if inbox else 'not in inbox')
    t.close()

    # ================================================================ the rule picks a named approval flow (2 levels)
    r = api(A, 'post', '/api/v1/tickets/flows/', {
        'name': 'rt-db-team', 'approval_level': 2,
        'rules': [{'users': {'type': 'ids', 'ids': [str(dba1.id), str(dba2.id)]}},
                  {'users': {'type': 'ids', 'ids': [str(lead.id)]}}]})
    check('an approval flow "rt-db-team" (level 1: the DBAs, level 2: the lead)', r.status_code == 201, r.data)
    flow = TicketFlow.objects.get(name='rt-db-team')
    flows = api(A, 'get', '/api/v1/accounts/jit-policies/approval-flows/').data
    mine = [f for f in flows if f['name'] == 'rt-db-team']
    check('the rule form lists the flows with who approves at each level',
          mine and [len(s['approvers']) for s in mine[0]['route']] == [2, 1] and any(f['default'] for f in flows), flows)
    db = host('rt-db')
    r = rule('rt-db-flow', db, approval_route='flow', approval_flow=str(flow.id))
    check('a rule with that flow', r.status_code == 201 and str(r.data['approval_flow']['id']) == str(flow.id), r.data.get('approval_flow'))
    p = api(U, 'post', '/api/v1/accounts/jit-access/preview/', {'assets': [str(db.id)], 'hours': 4}).data
    check('preview: the flow\'s two levels', [len(s['approvers']) for s in p['route']] == [2, 1] and p['flow'] == 'rt-db-team', p)
    t = selfservice.submit(Req(user), [db.id], 4)
    check('the request uses the rule\'s flow, level by level',
          t.flow_id == flow.id and steps(t) == [['rt.dba1', 'rt.dba2'], ['rt.lead']], (t.flow_id, steps(t)))
    check('... and says who approves (no "not automatic": the rule never approves by itself)',
          'Approval: level 1' in notes(t) and 'Not approved automatically' not in notes(t), notes(t))
    t.close()

    # ================================================================ approval flows from the rule form
    p = api(U, 'post', '/api/v1/accounts/jit-access/preview/', {'assets': [str(db.id)], 'hours': 4}).data
    check("preview: the rule decides the flow (the console form locks it)",
          p['policy_locks_flow'] is True and p['policy_flow_id'] == str(flow.id) and p['policies'] == ['rt-db-flow'], p)
    default = selfservice.org_flows(org.id).first()
    r = api(U, 'post', '/api/v1/tickets/apply-asset-tickets/open/', {
        'title': 'rt-other-flow', 'type': 'apply_asset', 'org_id': str(org.id), 'flow_id': str(default.id),
        'apply_assets': [str(db.id)], 'apply_nodes': [], 'apply_accounts': ['@JIT'], 'apply_actions': ['connect'],
        'apply_date_start': timezone.now().isoformat(),
        'apply_date_expired': (timezone.now() + timezone.timedelta(hours=4)).isoformat()})
    t = ApplyAssetTicket.objects.filter(title='rt-other-flow', applicant=user).first()
    check("a console request naming another flow gets the rule's flow",
          r.status_code == 201 and t and t.flow_id == flow.id and steps(t) == [['rt.dba1', 'rt.dba2'], ['rt.lead']],
          (r.status_code, t and t.flow_id, t and steps(t)))
    if t:
        t.close()
    from rbac.models import Role, Permission
    editor = mkuser('rt.ruleeditor')
    role = Role.objects.filter(name='rt-rule-editor').first() or Role.objects.create(name='rt-rule-editor', scope='org')
    role.permissions.set(Permission.objects.filter(
        content_type__app_label='accounts', codename__in=['view_jitpolicy', 'add_jitpolicy', 'change_jitpolicy']))
    org.add_member(editor, role=role)
    E = APIClient(); E.force_authenticate(editor)
    r = api(E, 'post', '/api/v1/accounts/jit-policies/approval-flows/', {
        'id': str(flow.id), 'name': 'rt-db-team', 'approval_level': 1,
        'rules': [{'level': 1, 'users': {'type': 'ids', 'ids': [str(editor.id)]}}]})
    check('someone who may only edit rules cannot change an approval flow', r.status_code == 403, r.status_code)
    r = api(A, 'patch', f'/api/v1/tickets/flows/{flow.id}/', {'cc_users': [str(dba2.id)]})
    r = api(A, 'post', '/api/v1/accounts/jit-policies/approval-flows/', {
        'id': str(flow.id), 'name': 'rt-db-team', 'approval_level': 2,
        'rules': [{'level': 1, 'users': {'type': 'ids', 'ids': [str(dba1.id), str(dba2.id)]}},
                  {'level': 2, 'users': {'type': 'ids', 'ids': [str(lead.id)]}}]})
    flow.refresh_from_db()
    check('editing a flow from the rule form keeps its CC users',
          r.status_code == 200 and list(flow.cc_users.values_list('username', flat=True)) == ['rt.dba2'], (r.status_code, r.data))
    five = [{'level': i, 'users': {'type': 'ids', 'ids': [str(u.id)]}} for i, u in enumerate([dba1, dba2, lead, dba1, dba2], 1)]
    r = api(A, 'post', '/api/v1/accounts/jit-policies/approval-flows/', {'name': 'rt-five', 'approval_level': 5, 'rules': five})
    check('a five-level flow can be made from the rule form', r.status_code == 201 and len(r.data['route']) == 5, r.data)
    r = api(A, 'post', '/api/v1/accounts/jit-policies/approval-flows/', {'name': 'rt-bad', 'approval_level': 'x', 'rules': []})
    check('a wrong level is refused, not an error', r.status_code == 400, r.status_code)

    # ================================================================ specific people
    r = rule('rt-db-people', db, priority=1, approval_route='approvers')
    check('"Specific people" without anyone chosen is refused', r.status_code == 400 and 'approvers' in r.data, r.data)
    r = rule('rt-db-people', db, priority=1, approval_route='approvers',
             approvers={'type': 'ids', 'ids': [str(lead.id)]})
    check('a rule approved by specific people', r.status_code == 201 and r.data['approval_route']['value'] == 'approvers', r.data)
    t = selfservice.submit(Req(user), [db.id], 4)
    check('the request goes to those people', steps(t) == [['rt.lead']], steps(t))
    t.close()
    r = api(A, 'patch', f'/api/v1/accounts/jit-policies/{r.data["id"]}/', {'approval_route': 'flow'})
    check('switching to "An approval flow" drops the people',
          r.status_code == 200 and not (r.data['approvers'] or {}).get('ids'), r.data)
    JITPolicy.objects.filter(name='rt-db-people').delete()

    # ================================================================ the console's request form
    start = timezone.now()
    form = {'assets': [str(web.id)], 'accounts': ['@JIT'], 'date_start': start.isoformat(),
            'date_expired': (start + timezone.timedelta(hours=168)).isoformat(), 'reason': ''}
    p = api(U, 'post', '/api/v1/accounts/jit-access/preview/', form).data
    check('console preview (dates, accounts): needs approval, says why', p['instant'] is False and '2 h' in p['why'], p)
    form['date_expired'] = (start + timezone.timedelta(hours=1)).isoformat()
    p = api(U, 'post', '/api/v1/accounts/jit-access/preview/', form).data
    check('console preview, 1 h: approved at once', p['instant'] is True, p)
    form['accounts'] = ['root']
    p = api(U, 'post', '/api/v1/accounts/jit-access/preview/', form).data
    check('console preview, an existing account: not instant, says so', p['instant'] is False and 'existing accounts' in p['why'], p)
    default = selfservice.org_flows(org.id).first()
    r = api(A, 'patch', f'/api/v1/accounts/jit-policies/{JITPolicy.objects.get(name="rt-db-flow").id}/',
            {'approval_flow': str(default.id)})
    listed = api(A, 'get', '/api/v1/accounts/jit-policies/')
    check('a rule with the global approval flow lists cleanly',
          r.status_code == 200 and listed.status_code == 200, (r.status_code, listed.status_code))
    r = api(U, 'post', '/api/v1/tickets/apply-asset-tickets/open/', {
        'title': 'ITP', 'type': 'apply_asset', 'org_id': str(org.id), 'flow_id': str(default.id),
        'apply_assets': [str(web.id)], 'apply_nodes': [], 'apply_accounts': ['@JIT'], 'apply_actions': ['all'],
        'apply_date_start': start.isoformat(), 'apply_date_expired': (start + timezone.timedelta(hours=168)).isoformat()})
    t = ApplyAssetTicket.objects.filter(title='ITP', applicant=user).order_by('-date_created').first()
    check('a console request of 168 h waits, with the same note (why, who)',
          r.status_code == 201 and t and t.state == 'pending' and 'Not approved automatically' in notes(t), (r.status_code, notes(t) if t else r.data))
    if t:
        t.close()
    JITPolicy.objects.filter(name='rt-web-2h').update(protocols=['ssh'])
    r = api(U, 'post', '/api/v1/tickets/apply-asset-tickets/open/', {
        'title': 'ITP-PROTO', 'type': 'apply_asset', 'org_id': str(org.id), 'flow_id': str(default.id),
        'apply_assets': [str(web.id)], 'apply_nodes': [], 'apply_accounts': ['@JIT'], 'apply_actions': ['all'],
        'apply_protocols': ['sftp'],
        'apply_date_start': start.isoformat(), 'apply_date_expired': (start + timezone.timedelta(hours=1)).isoformat()})
    tp = ApplyAssetTicket.objects.filter(title='ITP-PROTO', applicant=user).order_by('-date_created').first()
    check('a console request asking for a disallowed protocol is not auto-approved',
          r.status_code == 201 and tp and tp.state == 'pending' and 'only allows ssh' in notes(tp),
          (r.status_code, notes(tp) if tp else r.data))
    if tp:
        tp.close()
    JITPolicy.objects.filter(name='rt-web-2h').update(protocols=['all'], actions=1 | 4)  # connect + download
    form['accounts'], form['date_expired'] = ['@JIT'], (start + timezone.timedelta(hours=1)).isoformat()
    p = api(U, 'post', '/api/v1/accounts/jit-access/preview/', dict(form, actions=['all'])).data
    check('console preview asking for all actions where the rule limits them: not instant, says so',
          p['instant'] is False and 'actions' in p['why'], p)
    p = api(U, 'post', '/api/v1/accounts/jit-access/preview/', dict(form, actions=['connect'])).data
    check('... asking only what the rule allows: approved at once', p['instant'] is True, p)
    # ================================================================ console: reason required, request shortened
    pure = host('rt-pure')
    rule('rt-pure-2h', pure, auto_approve=True, auto_approve_max_hours=2, max_hours=2, require_reason=True)
    default = selfservice.org_flows(org.id).first()

    def console(title, comment, hours):
        start = timezone.now()
        r = api(U, 'post', '/api/v1/tickets/apply-asset-tickets/open/', {
            'title': title, 'comment': comment, 'type': 'apply_asset', 'org_id': str(org.id),
            'flow_id': str(default.id), 'apply_assets': [str(pure.id)], 'apply_nodes': [], 'apply_accounts': ['@JIT'],
            'apply_actions': ['connect'], 'apply_date_start': start.isoformat(),
            'apply_date_expired': (start + timezone.timedelta(hours=hours)).isoformat()})
        return r, ApplyAssetTicket.objects.filter(title=title, applicant=user).order_by('-date_created').first()

    r, t = console('rt-title-only', '', 1)
    check('a console request with a title but no reason is not instant when the rule asks for a reason',
          t and t.state == 'pending' and 'no reason given' in notes(t), (r.status_code, t and t.state, t and notes(t)))
    if t:
        t.close()
    reset()
    r, t = console('rt-too-long', 'patching the kernel', 168)
    hours = t and round((t.apply_date_expired - t.apply_date_start).total_seconds() / 3600, 1)
    check('a request longer than the rule ever allows is shortened to it, approved, and says so',
          t and t.state == 'approved' and hours == 2.0 and 'Shortened from 168 h to 2 h' in notes(t),
          (t and t.state, hours, t and notes(t)))
    reset()
    # ================================================================ extensions
    from perms.models import AssetPermission
    ext = host('rt-ext')
    r = rule('rt-ext', ext, auto_approve=True, auto_approve_max_hours=2, max_hours=4, max_extensions=1)
    ext_rule = r.data['id']
    t = selfservice.submit(Req(user), [ext.id], 1, reason='deploy')
    perm = AssetPermission.objects.filter(from_ticket=True, users=user, assets=ext).order_by('-date_created').first()
    check('an access to extend', t.state == 'approved' and perm is not None, t.state)

    def extend(hours, reason='more time'):
        try:
            return selfservice.extend(Req(user), perm.id, hours, reason=reason)
        except selfservice.SelfServiceError as e:
            return str(e)

    e1 = extend(1)
    check('an extension within the rule is approved by itself', getattr(e1, 'state', e1) == 'approved', getattr(e1, 'state', e1))
    e2 = extend(1)
    check('... a second one is refused (one extension allowed)', isinstance(e2, str) and 'Maximum number of extensions' in e2, e2)
    api(A, 'patch', f'/api/v1/accounts/jit-policies/{ext_rule}/', {'max_extensions': 0, 'extension_approval': 'manual'})
    e3 = extend(1)
    check('"always manual": the extension waits for an approver, and says why',
          getattr(e3, 'state', None) == 'pending' and 'manual approval for extensions' in notes(e3), getattr(e3, 'state', e3))
    if not isinstance(e3, str):
        e3.close()
    api(A, 'patch', f'/api/v1/accounts/jit-policies/{ext_rule}/', {'auto_approve': False, 'extension_approval': 'auto'})
    e4 = extend(1)
    check('"approve extensions automatically" even where the rule does not approve requests by itself',
          getattr(e4, 'state', e4) == 'approved', getattr(e4, 'state', e4))
    api(A, 'patch', f'/api/v1/accounts/jit-policies/{ext_rule}/', {'allow_extension': False})
    e5 = extend(1)
    check('extensions switched off: refused', isinstance(e5, str) and 'does not allow extending' in e5, e5)
    r = api(A, 'patch', f'/api/v1/accounts/jit-policies/{ext_rule}/', {'allow_extension': True, 'extension_max_hours': 10})
    check('a longest extension above the longest access is refused', r.status_code == 400 and 'extension_max_hours' in r.data, r.data)
    reset()

    # ================================================================ who sees which tickets
    from rbac.builtin import BuiltinRole
    oadmin = mkuser('rt.orgadmin')
    org.add_member(oadmin, role=BuiltinRole.org_admin.get_role())
    other_org = Organization.objects.filter(name='rt-other').first() or Organization.objects.create(name='rt-other')
    boss = mkuser('rt.boss')
    other_org.add_member(boss, role=BuiltinRole.org_admin.get_role())
    from orgs.utils import tmp_to_org
    with tmp_to_org(org):
        org.members.through.objects.filter(user=boss, role_id=BuiltinRole.org_admin.id).delete()
    set_current_org(org)

    def ticket_titles(u):
        c = APIClient(); c.force_authenticate(u)
        r = c.get('/api/v1/tickets/tickets/?limit=500', HTTP_X_JMS_ORG=str(org.id))
        set_current_org(org)
        rows = r.data.get('results', r.data) if isinstance(r.data, dict) else r.data
        return {row['title'] for row in rows}

    mine = {t.title for t in ApplyAssetTicket.objects.filter(applicant=user)}
    check("an organization's admin sees its tickets in All Submitted Tickets", mine and mine <= ticket_titles(oadmin), len(mine))
    check("another organization's admin does not", not (mine & ticket_titles(boss)), sorted(mine & ticket_titles(boss))[:3])
    nobody = mkuser('rt.nobody')
    check("a user who is neither applicant nor approver sees none of them", not (ticket_titles(nobody) & mine),
          sorted(ticket_titles(nobody) & mine)[:3])

    p = api(U, 'post', '/api/v1/accounts/jit-access/preview/', {'assets': [], 'hours': 1}).data
    check('preview of nothing: nothing to say', p['instant'] is False and p['route'] == [], p)
except Exception:
    traceback.print_exc()
    check('no error', False)
finally:
    cleanup()

print(f'RESULT: {sum(results)}/{len(results)} passed')
sys.exit(0 if all(results) else 1)
