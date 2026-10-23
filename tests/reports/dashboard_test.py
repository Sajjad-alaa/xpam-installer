"""Isolated stack: custom dashboards — who can manage them (role permissions: organization administrators, not
auditors or users), who sees which (shared with people, groups, the whole organization, or private), organizations
kept apart, and widgets checked against the catalog."""
import os, sys, traceback
sys.path.insert(0, '/opt/jumpserver/apps'); os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'jumpserver.settings')
import django; django.setup()
from django.conf import settings
settings.ALLOWED_HOSTS = list(settings.ALLOWED_HOSTS) + ['testserver']
import xpack.utils
xpack.utils.get_license_user_limit = lambda: 20
from rest_framework.test import APIClient
from orgs.models import Organization
from orgs.utils import set_current_org, tmp_to_root_org
from rbac.builtin import BuiltinRole
from reports.models import CustomDashboard
from users.models import User, UserGroup

results = []


def check(name, ok, detail=''):
    results.append(bool(ok))
    print(('PASS ' if ok else 'FAIL ') + name + (f'  [{str(detail)[:240]}]' if detail != '' else ''), flush=True)


org = Organization.default(); set_current_org(org)
H = {'HTTP_X_JMS_ORG': str(org.id)}
URL = '/api/v1/reports/custom-dashboards/'


def mkuser(name, role=None, o=org):
    u = User.objects.filter(username=name).first() or User.objects.create(
        username=name, name=name, email=f'{name}@example.invalid', is_first_login=False)
    o.add_member(u, role=role)
    return u


def client(u):
    c = APIClient(); c.force_authenticate(u)
    return c


def names(c, h=H):
    r = c.get(URL, **h)
    set_current_org(org)
    rows = r.data if isinstance(r.data, list) else r.data.get('results', [])
    return sorted(d['name'] for d in rows if d['name'].startswith('cd-'))


try:
    admin = mkuser('cd.admin', BuiltinRole.org_admin.get_role())
    auditor = mkuser('cd.auditor', BuiltinRole.org_auditor.get_role())
    u1, u2 = mkuser('cd.user1'), mkuser('cd.user2')
    group = UserGroup.objects.filter(name='cd-group').first() or UserGroup.objects.create(name='cd-group')
    group.users.add(u2)
    A, AU, U1, U2 = client(admin), client(auditor), client(u1), client(u2)

    check('an organization admin may manage dashboards', admin.has_perm('reports.add_customdashboard')
          and admin.has_perm('reports.delete_customdashboard'))
    check('an auditor and a user may not', not auditor.has_perm('reports.add_customdashboard')
          and not u1.has_perm('reports.add_customdashboard'))
    cat = {n: c.get(URL + 'catalog/', **H).data['can_manage'] for n, c in (('admin', A), ('auditor', AU), ('user', U1))}
    check('the catalog says who may manage', cat == {'admin': True, 'auditor': False, 'user': False}, cat)

    layout = [{'widget': 'console_realtime', 'span': 12}]
    made = {}
    for name, extra in (('cd-people', {'shared_users': [str(u1.id)]}), ('cd-group', {'shared_groups': [str(group.id)]}),
                        ('cd-all', {'is_shared_all': True}), ('cd-private', {})):
        r = A.post(URL, dict({'name': name, 'layout': layout, 'scope': 'console'}, **extra), format='json', **H)
        set_current_org(org)
        made[name] = r.data.get('id')
        check(f'the admin creates {name}', r.status_code == 201, r.data)
    check('the admin sees all four', names(A) == ['cd-all', 'cd-group', 'cd-people', 'cd-private'], names(A))
    check('user 1 sees the one shared with them and the organization one', names(U1) == ['cd-all', 'cd-people'], names(U1))
    check('user 2 sees the group one and the organization one', names(U2) == ['cd-all', 'cd-group'], names(U2))
    check('the auditor sees only the organization one', names(AU) == ['cd-all'], names(AU))
    r = U1.get(URL + f'{made["cd-private"]}/', **H); set_current_org(org)
    check("a user cannot open someone's private dashboard", r.status_code == 404, r.status_code)

    r = U1.patch(URL + f'{made["cd-people"]}/', {'name': 'cd-hacked'}, format='json', **H); set_current_org(org)
    check('a user cannot change a dashboard shared with them', r.status_code == 403, r.status_code)
    r = AU.post(URL, {'name': 'cd-auditor', 'layout': layout}, format='json', **H); set_current_org(org)
    check('an auditor cannot create one', r.status_code == 403, r.status_code)
    r = AU.post(URL + f'{made["cd-all"]}/clone/', {}, format='json', **H); set_current_org(org)
    check('... nor clone one', r.status_code == 403, r.status_code)
    r = U1.delete(URL + f'{made["cd-all"]}/', **H); set_current_org(org)
    check('a user cannot delete one', r.status_code == 403, r.status_code)
    r = A.post(URL, {'name': 'cd-bad', 'layout': [{'widget': 'rm -rf'}]}, format='json', **H); set_current_org(org)
    check('an unknown widget is refused', r.status_code == 400, r.data)

    other = Organization.objects.filter(name='cd-other').first() or Organization.objects.create(name='cd-other')
    boss = mkuser('cd.boss', BuiltinRole.org_admin.get_role(), o=other)
    from orgs.utils import tmp_to_org
    with tmp_to_org(org):  # (new users join the Default organization: take this one out)
        org.members.through.objects.filter(user=boss).delete()
    set_current_org(org)
    check('(the outsider is not a member of this organization)', not org.get_members().filter(id=boss.id).exists())
    check("another organization's admin sees none of these", names(client(boss), {'HTTP_X_JMS_ORG': str(other.id)}) == [])
    r = A.patch(URL + f'{made["cd-people"]}/', {'shared_users': [str(boss.id)]}, format='json', **H); set_current_org(org)
    check('sharing with someone outside the organization is ignored',
          r.status_code == 200 and r.data['shared_users'] == [], r.data.get('shared_users'))
except Exception:
    traceback.print_exc()
    check('no error', False)
finally:
    with tmp_to_root_org():
        CustomDashboard.objects.filter(name__startswith='cd-').delete()

print(f'RESULT: {sum(results)}/{len(results)} passed')
sys.exit(0 if all(results) else 1)
