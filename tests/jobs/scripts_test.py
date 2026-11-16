"""Isolated stack (tests/jobs/engine_run.sh, TEST=scripts_test.py): XPAM Automation scripts. A script with typed
parameters runs on servers and every server gets its own result (worked, failed with its exit code, unreachable,
skipped); parameters reach it as environment variables and stay data; secret values are masked in everything kept;
the owner's rules: a script that is not approved runs only for its author and not on production servers, approval
by another person, every change needs a new approval, sharing needs approval; retry on the failed servers; CSV."""
import csv, io, json, os, sys, time, traceback, uuid
sys.path.insert(0, '/opt/core/apps'); os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'xpam.settings')
import django; django.setup()
from django.conf import settings
settings.ALLOWED_HOSTS = list(settings.ALLOWED_HOSTS) + ['testserver']
settings.SECURITY_COMMAND_EXECUTION = True
import xpack.utils
xpack.utils.get_license_asset_count = lambda: 10
xpack.utils.get_license_user_limit = lambda: 10
xpack.utils.has_automation_license = lambda: True
from django.contrib.contenttypes.models import ContentType
from rest_framework.test import APIClient
from orgs.models import Organization
from orgs.utils import set_current_org
from assets.models import Platform, Node, Asset
from labels.models import Label, LabeledResource
from ops.models import Job, JobExecution, JobExecutionHost, Script
from ops.tasks import _run_ops_job_execution
from ops.utils import get_task_log_path
from perms.const import ActionChoices
from perms.models import AssetPermission
from rbac.builtin import BuiltinRole
from rbac.models import Role, RoleBinding
from users.models import User

ROOT_PW = os.environ['ROOT_PASSWORD']
SECRET = 'S3cr3t-' + uuid.uuid4().hex[:10]
results = []


def check(name, ok, detail=''):
    results.append(bool(ok))
    print(('PASS ' if ok else 'FAIL ') + name + (f'  [{str(detail)[:400]}]' if detail != '' and not ok else ''), flush=True)


org = Organization.default()
set_current_org(org)
admin = User.objects.get(username='admin')
H = {'HTTP_X_JMS_ORG': str(org.id)}
root = Node.org_root()


def make_user(username):
    u = User.objects.filter(username=username).first() or User.objects.create(
        username=username, name=username, email=username + '@example.invalid', is_first_login=False)
    org.add_member(u)
    RoleBinding.objects.get_or_create(user=u, role=Role.objects.get(id=BuiltinRole.org_automation_operator.id),
                                      org_id=org.id, scope='org')
    u.expire_rbac_perms_cache()
    c = APIClient(); c.force_authenticate(User.objects.get(id=u.id))
    return u, c


author, A = make_user('script.author')
other, O = make_user('script.other')
ADMIN = APIClient(); ADMIN.force_authenticate(admin)


def api(client, method, url, data=None, **kw):
    r = getattr(client, method)(url, data, format='json', **H, **kw)
    set_current_org(org)
    return r


def asset(name, address):
    a = Asset.objects.filter(name=name).first()
    if a:
        return a
    r = api(ADMIN, 'post', '/api/v1/assets/hosts/', {
        'name': name, 'address': address, 'platform': Platform.objects.get(name='Linux').id,
        'nodes': [str(root.id)], 'protocols': [{'name': 'ssh', 'port': 22}],
        'accounts': [{'name': 'root', 'username': 'root', 'secret_type': 'password', 'secret': ROOT_PW,
                      'privileged': True}]})
    assert r.status_code == 201, r.data
    return Asset.objects.get(id=r.data['id'])


def run_now(response):
    """The run the API started, executed as the worker does (no worker in the test stack)."""
    assert response.status_code == 201, (response.status_code, response.data)
    ex = JobExecution.objects.get(id=response.data['execution'])
    _run_ops_job_execution(ex)
    set_current_org(org)
    return JobExecution.objects.get(id=ex.id)


def rows(ex):
    return {h.name: h for h in JobExecutionHost.objects.filter(execution=ex)}


try:
    host = asset('sc-linux', 'jobhost')
    down = asset('sc-down', 'jobnowhere.invalid')
    prod = asset('sc-prod', 'jobhost')
    label, _ = Label.objects.get_or_create(name='env', value='production', org_id=org.id)
    LabeledResource.objects.get_or_create(label=label, res_type=ContentType.objects.get_for_model(Asset),
                                          res_id=str(prod.id), org_id=org.id)
    AssetPermission.objects.filter(name='sc-perm').delete()
    perm = AssetPermission.objects.create(name='sc-perm', org_id=org.id, accounts=['@ALL'], protocols=['all'],
                                          actions=ActionChoices.all())
    perm.users.add(author, other); perm.assets.add(host, down, prod)
    Script.objects.filter(name__startswith='sc-').delete()

    # ================================================================ write a script
    body = {
        'name': 'sc-report', 'interpreter': 'bash', 'timeout': 60,
        'content': '#!/bin/bash\necho "who=$(id -un) site=$SITE count=$COUNT mode=$MODE flag=$FLAG"\n'
                   'echo "token=$TOKEN"\necho "raw=$RAW"\n[ "$MODE" = fail ] && exit 3\nexit 0\n',
        'parameters': [
            {'name': 'SITE', 'type': 'text', 'required': True},
            {'name': 'COUNT', 'type': 'number', 'default': '2'},
            {'name': 'MODE', 'type': 'choice', 'choices': ['ok', 'fail'], 'default': 'ok'},
            {'name': 'FLAG', 'type': 'boolean', 'default': 'no'},
            {'name': 'TOKEN', 'type': 'secret', 'required': True},
            {'name': 'RAW', 'type': 'text'},
        ],
    }
    r = api(A, 'post', '/api/v1/ops/scripts/', body)
    check('an Automation operator writes a script; it starts as a draft, version 1',
          r.status_code == 201 and r.data['state']['value'] == 'draft' and r.data['version'] == 1, r.data)
    sid = r.data['id']
    for bad, what in (({'name': 'PATH'}, 'a reserved name'), ({'name': '1X'}, 'an invalid name'),
                      ({'name': 'C', 'type': 'choice'}, 'a choice without options')):
        r = api(A, 'post', '/api/v1/ops/scripts/', dict(body, name='sc-bad-' + uuid.uuid4().hex[:4], parameters=[bad]))
        check(f'a parameter with {what} is refused', r.status_code == 400, r.data)

    # ================================================================ run it: values as environment variables
    params = {'SITE': 'north', 'MODE': 'ok', 'FLAG': 'yes', 'TOKEN': SECRET,
              'RAW': '$(touch /tmp/sc-pwned) {{ lookup("pipe", "id") }} \'"; exit 9'}
    ex = run_now(api(A, 'post', f'/api/v1/ops/scripts/{sid}/run/',
                     {'assets': [str(host.id), str(down.id)], 'parameters': params}))
    rr = rows(ex)
    h = rr.get('sc-linux')
    check('the script worked on the reachable server, with exit code 0', h and h.status == 'worked' and h.rc == 0,
          h and (h.status, h.rc, h.stdout, h.stderr, h.reason))
    check('the parameters reached the script as environment variables (defaults and yes/no included)',
          h and 'who=root site=north count=2 mode=ok flag=true' in h.stdout, h and h.stdout)
    check('a value is data: no command substitution, no template, quotes kept',
          h and '$(touch /tmp/sc-pwned) {{ lookup("pipe", "id") }}' in h.stdout and 'uid=' not in h.stdout,
          h and h.stdout)
    from paramiko import SSHClient, AutoAddPolicy
    c = SSHClient(); c.set_missing_host_key_policy(AutoAddPolicy())
    c.connect('jobhost', username='root', password=ROOT_PW, look_for_keys=False, allow_agent=False)
    _, out, _ = c.exec_command('ls /tmp/sc-pwned 2>/dev/null; ls -a /root/.ansible/tmp 2>/dev/null | grep -c ansible-tmp')
    left = out.read().decode(); c.close()
    check('nothing ran from a value, and the script was removed from the server', 'sc-pwned' not in left
          and left.strip().splitlines()[-1:] in (['0'], []), left)
    d = rr.get('sc-down')
    check('a server that cannot be reached is reported as unreachable', d and d.status == 'unreachable', d and (d.status, d.reason))
    stored = json.dumps([h.stdout, h.stderr, d.reason if d else '']) + json.dumps(ex.result) + json.dumps(ex.summary)
    log = get_task_log_path(settings.ANSIBLE_LOG_DIR, ex.id, create=False)
    stored += open(log, errors='replace').read() if os.path.isfile(log) else ''
    check('the secret value is masked in the result, the run and its log', SECRET not in stored
          and 'token=********' in h.stdout, h.stdout)
    check('the secret value is not kept after the run', not JobExecution.objects.get(id=ex.id).secret_parameters
          and SECRET not in json.dumps(ex.parameters) and SECRET not in (ex.job.args or ''))

    r = api(A, 'get', f'/api/v1/ops/job-executions/{ex.id}/hosts/')
    check('the run reports a result per server with totals',
          r.status_code == 200 and r.data['totals'].get('worked') == 1 and r.data['totals'].get('unreachable') == 1, r.data)
    r = A.get(f'/api/v1/ops/job-executions/{ex.id}/hosts/?export=csv', **H)
    set_current_org(org)
    table = list(csv.reader(io.StringIO(r.content.decode())))
    check('the results export as CSV', r.status_code == 200 and table[0][:2] == ['name', 'status'] and len(table) == 3,
          r.content[:300])

    # ================================================================ failures, the success rule, retry
    ex2 = run_now(api(A, 'post', f'/api/v1/ops/scripts/{sid}/run/',
                      {'assets': [str(host.id)], 'parameters': dict(params, MODE='fail')}))
    h2 = rows(ex2).get('sc-linux')
    check('a script that exits with 3 failed on that server, exit code 3', h2 and h2.status == 'failed' and h2.rc == 3,
          h2 and (h2.status, h2.rc))
    r = api(A, 'post', f'/api/v1/ops/job-executions/{ex.id}/retry-failed/', {'parameters': {'TOKEN': SECRET}})
    check('run again on the failed servers: only the unreachable one', r.status_code == 201 and r.data['servers'] == 1, r.data)
    ex3 = run_now(r)
    check('the retry ran on that server only', set(rows(ex3)) == {'sc-down'}, set(rows(ex3)))
    r = api(A, 'post', f'/api/v1/ops/job-executions/{ex.id}/retry-failed/', {})
    check('a retry needs the secret values again (they are not kept)', r.status_code == 400, r.data)
    for bad, what in (({'SITE': 'x', 'TOKEN': 'y', 'MODE': 'maybe'}, 'a value not among the choices'),
                      ({'TOKEN': 'y'}, 'a missing required value'),
                      ({'SITE': 'x', 'TOKEN': 'y', 'COUNT': 'many'}, 'a number that is not one'),
                      ({'SITE': 'x', 'TOKEN': 'y', 'OTHER': '1'}, 'an unknown parameter')):
        r = api(A, 'post', f'/api/v1/ops/scripts/{sid}/run/', {'assets': [str(host.id)], 'parameters': bad})
        check(f'a run with {what} is refused', r.status_code == 400, r.data)

    # ================================================================ owner's rules
    r = api(A, 'post', f'/api/v1/ops/scripts/{sid}/run/', {'assets': [str(prod.id)], 'parameters': params})
    check('a draft does not run on a production server (tag env:production)', r.status_code == 403
          and 'production' in str(r.data), r.data)
    r = api(O, 'get', f'/api/v1/ops/scripts/{sid}/')
    check('another user does not see a draft', r.status_code == 404, r.status_code)
    r = api(A, 'patch', f'/api/v1/ops/scripts/{sid}/', {'sharing': 'org'})
    r = api(A, 'post', f'/api/v1/ops/scripts/{sid}/submit/')
    check('the author submits it for approval', r.status_code == 200 and r.data['state']['value'] == 'pending', r.data)
    r = api(A, 'post', f'/api/v1/ops/scripts/{sid}/approve/', {'comment': 'mine'})
    check('the author cannot approve their own script', r.status_code == 403, (r.status_code, r.data))
    r = api(ADMIN, 'post', f'/api/v1/ops/scripts/{sid}/approve/', {'comment': 'reviewed'})
    check('an administrator approves it', r.status_code == 200 and r.data['is_approved'], r.data)
    ex4 = run_now(api(A, 'post', f'/api/v1/ops/scripts/{sid}/run/', {'assets': [str(prod.id)], 'parameters': params}))
    check('the approved script runs on the production server', rows(ex4).get('sc-prod') is not None
          and rows(ex4)['sc-prod'].status == 'worked', {k: v.status for k, v in rows(ex4).items()})
    r = api(O, 'get', f'/api/v1/ops/scripts/{sid}/')
    check('once approved and shared, the organization sees it', r.status_code == 200, r.status_code)
    ex5 = run_now(api(O, 'post', f'/api/v1/ops/scripts/{sid}/run/', {'assets': [str(host.id)], 'parameters': params}))
    check('another operator runs the approved script', rows(ex5).get('sc-linux') and rows(ex5)['sc-linux'].status == 'worked')
    r = api(O, 'patch', f'/api/v1/ops/scripts/{sid}/', {'content': 'echo changed\n'})
    check('only the author changes a script', r.status_code == 403, r.status_code)
    r = api(A, 'patch', f'/api/v1/ops/scripts/{sid}/', {'content': body['content'] + '# changed\n'})
    check('a change makes a new version and the approval is gone',
          r.status_code == 200 and r.data['version'] == r.data['approved_version'] + 1 and not r.data['is_approved']
          and r.data['state']['value'] == 'draft', r.data)
    r = api(A, 'post', f'/api/v1/ops/scripts/{sid}/run/', {'assets': [str(prod.id)], 'parameters': params})
    check('the changed script no longer runs on production', r.status_code == 403, r.status_code)
    r = api(O, 'post', f'/api/v1/ops/scripts/{sid}/run/', {'assets': [str(host.id)], 'parameters': params})
    check('and no longer for the others', r.status_code in (403, 404), r.status_code)

    # ================================================================ success rule
    r = api(A, 'post', '/api/v1/ops/scripts/', {'name': 'sc-rule', 'interpreter': 'sh', 'content': 'echo nothing to see\n',
                                                'success_text': 'ALL GOOD'})
    ex6 = run_now(api(A, 'post', f"/api/v1/ops/scripts/{r.data['id']}/run/", {'assets': [str(host.id)]}))
    h6 = rows(ex6).get('sc-linux')
    check('with "worked when the output contains": exit 0 without that text counts as failed',
          h6 and h6.status == 'failed' and 'ALL GOOD' in h6.reason, h6 and (h6.status, h6.reason))
    r = api(A, 'post', '/api/v1/ops/scripts/', {'name': 'sc-py', 'interpreter': 'python3',
                                                'content': 'import os\nprint("py", 6 * 7, os.environ.get("X"))\n',
                                                'parameters': [{'name': 'X', 'default': 'ok'}]})
    ex7 = run_now(api(A, 'post', f"/api/v1/ops/scripts/{r.data['id']}/run/", {'assets': [str(host.id)]}))
    h7 = rows(ex7).get('sc-linux')
    check('a Python script runs with python3', h7 and h7.status == 'worked' and 'py 42 ok' in h7.stdout,
          h7 and (h7.status, h7.stdout, h7.stderr, h7.reason))

    # ================================================================ licence
    xpack.utils.has_automation_license = lambda: False
    r = api(A, 'get', '/api/v1/ops/scripts/')
    check('without Automation in the licence scripts are refused', r.status_code == 403, r.status_code)
    xpack.utils.has_automation_license = lambda: True
    from ops.notifications import JobFinishedMsg
    msg = JobFinishedMsg(author, ex).get_html_msg()
    check('the author is told how a run ended', 'sc-report' in msg['message'] and 'Worked: 1' in msg['message'], msg)
except Exception:
    traceback.print_exc()
    results.append(False)
print(f'DONE {sum(results)} passed, {len(results) - sum(results)} failed', flush=True)
