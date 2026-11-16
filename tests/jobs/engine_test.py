"""Isolated stack: the job centre's engine. A user's jobs (command, file upload, database query, playbook) work and
report a result per server; and nothing a user writes in a job is run or read on the XPAM server itself: template
syntax, lookups, stored secrets, further module options in the upload folder or in a database query, the job's name
as a folder. The jobs are started as the worker starts them (ops.tasks._run_ops_job_execution)."""
import json, os, sys, time, traceback, uuid
sys.path.insert(0, '/opt/core/apps'); os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'xpam.settings')
import django; django.setup()
from django.conf import settings
settings.ALLOWED_HOSTS = list(settings.ALLOWED_HOSTS) + ['testserver']
settings.SECURITY_COMMAND_EXECUTION = True   # (the job centre is off until an administrator turns it on)
import xpack.utils
xpack.utils.get_license_asset_count = lambda: 10   # (the test needs two targets; the trial allows one)
xpack.utils.has_automation_license = lambda: True  # (Automation is a licensed feature; checked below)
import paramiko
from rest_framework.test import APIClient
from orgs.models import Organization
from orgs.utils import set_current_org
from assets.models import Platform, Node, Asset
from ops.models import Job, JobExecution, Playbook
from ops.tasks import _run_ops_job_execution
from ops.utils import get_task_log_path
from perms.const import ActionChoices
from perms.models import AssetPermission
from users.models import User

ROOT_PW = os.environ['ROOT_PASSWORD']
TPW = os.environ['TARGET_PG_PASSWORD']
RUNNER = os.environ.get('RUNNER') == '1'
MARK = 'server-only-' + uuid.uuid4().hex          # content of a file only the XPAM server has
SERVER_FILE = '/opt/core/data/server-only.txt'
results = []


def check(name, ok, detail=''):
    results.append(bool(ok))
    print(('PASS ' if ok else 'FAIL ') + name + (f'  [{str(detail)[:300]}]' if detail != '' and not ok else ''), flush=True)


def info(text):
    print('INFO ' + str(text)[:380], flush=True)


def target(cmd):
    c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect('jobhost', 22, username='root', password=ROOT_PW, timeout=10, look_for_keys=False, allow_agent=False)
    try:
        _, out, err = c.exec_command(cmd, timeout=20)
        return (out.read() + err.read()).decode(errors='replace')
    finally:
        c.close()


org = Organization.default()
set_current_org(org)
admin = User.objects.get(username='admin')
user = User.objects.filter(username='job.user').first() or User.objects.create(
    username='job.user', name='Job User', email='job.user@example.invalid', is_first_login=False)
org.add_member(user)
A = APIClient(); A.force_authenticate(admin)
H = {'HTTP_X_JMS_ORG': str(org.id)}
root = Node.org_root()


def api_asset(url, data):
    r = A.post(url, data, format='json', **H)
    set_current_org(org)
    assert r.status_code == 201, r.data
    return Asset.objects.get(id=r.data['id'])


def run(assets, parameters=None, name=None, **job):
    """A job of the user, run as the worker runs it; returns the execution and every text it produced."""
    job.setdefault('runas', 'root')
    j = Job.objects.create(name=name or 'job-' + uuid.uuid4().hex[:10], instant=name is None, creator=user,
                           org_id=org.id, runas_policy='privileged_first', **job)
    j.assets.set(assets)
    ex = j.create_execution()
    ex.creator = user
    ex.task_id = ex.id
    if parameters:
        ex.parameters = parameters
    ex.save()
    _run_ops_job_execution(ex)
    set_current_org(org)
    ex = JobExecution.objects.get(id=ex.id)
    text = json.dumps(ex.result, default=str) + json.dumps(ex.summary, default=str)
    path = get_task_log_path(settings.ANSIBLE_LOG_DIR, ex.id, create=False)
    if os.path.isfile(path):
        text += open(path, errors='replace').read()
    return ex, text


def shell(args, **kw):
    return run([host], type='adhoc', module='shell', args=args, **kw)


def query(args, **kw):
    return run([db], type='adhoc', module='postgresql', args=args, runas='postgres', **kw)


try:
    with open(SERVER_FILE, 'w') as f:
        f.write(MARK)
    host = Asset.objects.filter(name='job-linux').first() or api_asset('/api/v1/assets/hosts/', {
        'name': 'job-linux', 'address': 'jobhost', 'platform': Platform.objects.get(name='Linux').id,
        'nodes': [str(root.id)], 'protocols': [{'name': 'ssh', 'port': 22}, {'name': 'sftp', 'port': 22}],
        'accounts': [{'name': 'root', 'username': 'root', 'secret_type': 'password', 'secret': ROOT_PW,
                      'privileged': True}]})
    AssetPermission.objects.filter(name='job-perm').delete()
    perm = AssetPermission.objects.create(name='job-perm', org_id=org.id, accounts=['@ALL'], protocols=['all'],
                                          actions=ActionChoices.all())
    perm.users.add(user); perm.assets.add(host)

    # ================================================================ who may use Automation (owner, 2026-11-16)
    from rbac.builtin import BuiltinRole
    from rbac.models import Role, RoleBinding
    U = APIClient(); U.force_authenticate(user)

    def jobs_api():
        r = U.get('/api/v1/ops/jobs/', **H)
        set_current_org(org)
        return r

    RoleBinding.objects.filter(user=user, role_id=BuiltinRole.org_automation_operator.id).delete()
    r = jobs_api()
    check('an ordinary user has no Job centre until an administrator grants it', r.status_code == 403, r.status_code)
    RoleBinding.objects.create(user=user, role=Role.objects.get(id=BuiltinRole.org_automation_operator.id),
                               org_id=org.id, scope='org')
    user.expire_rbac_perms_cache()   # (the role API does this; a binding made here does not)
    U.force_authenticate(User.objects.get(id=user.id))
    info('Automation operator role: %d permissions' % Role.objects.get(id=BuiltinRole.org_automation_operator.id).permissions.count())
    xpack.utils.has_automation_license = lambda: False
    r = jobs_api()
    check('with the Automation operator role but no Automation in the licence: refused',
          r.status_code == 403 and 'licence' in str(r.data), (r.status_code, r.data))
    xpack.utils.has_automation_license = lambda: True
    r = jobs_api()
    check('with the role and the licence the Job centre opens', r.status_code == 200, (r.status_code, r.data))
    r = U.get('/api/v1/settings/public/open/', **H)
    set_current_org(org)
    check('the console learns whether Automation is licensed', r.data.get('HAS_AUTOMATION_LICENSE') is True, r.data)

    # ================================================================ commands: they work, with a result per server
    ex, text = shell('echo job-$((40+2)); id -un')
    check('a command runs on the server and its output comes back', ex.status == 'success' and 'job-42' in text
          and 'root' in text, (ex.status, text))
    check('the result names the server it worked on', 'job-linux' in json.dumps(ex.summary.get('ok', [])), ex.summary)
    ex, text = shell('echo before-fail; exit 3')
    check('a failing command is reported as failed, with the server and its exit code',
          ex.status == 'failed' and 'job-linux' in json.dumps(ex.summary.get('failures', {}))
          and '"rc": 3' in json.dumps(ex.result), (ex.status, ex.summary))
    ex, text = shell('echo who={{ jms_username }}=')
    check('job variables still work in a command', 'who=job.user=' in text, text)

    # ================================================================ commands: nothing runs or is read on XPAM
    for lookup in ('pipe', 'ansible.builtin.pipe', 'lines'):
        ex, text = shell('echo x={{ lookup("%s", "echo ctl-$((40+2)); touch /tmp/ctl-%s") }}' % (lookup, lookup[-4:]))
        check(f'template lookup `{lookup}` in a command does not run on the XPAM server',
              'ctl-42' not in text and not os.path.exists('/tmp/ctl-' + lookup[-4:]), text)
    ex, text = shell('echo x={{ lookup("file", "%s") }}' % SERVER_FILE)
    check('template lookup `file` in a command does not read a file of the XPAM server', MARK not in text, text)
    for expr in ('ansible_password', 'jms_account.secret', 'hostvars[inventory_hostname].ansible_password',
                 'lookup("vars", "ansible_password")'):
        ex, text = shell('echo p={{ %s }}=' % expr)
        check(f'the stored password is not shown by {{{{ {expr} }}}}', ROOT_PW not in text, text)
    ex, text = shell('echo c={{ "".__class__.__mro__[1].__subclasses__() | length }}=')
    check('templates cannot walk into Python internals', ex.status != 'success' or 'c==' in text, text)

    # ================================================================ file upload
    def upload(dst_path, filename='hello.txt'):
        j = Job.objects.create(name='upload_file-' + uuid.uuid4().hex[:10], creator=user, org_id=org.id,
                               type='upload_file', args=json.dumps({'dst_path': dst_path}), runas='root',
                               runas_policy='privileged_first')
        j.assets.set([host])
        folder = os.path.join(settings.SHARE_DIR, 'job_upload_file', str(j.id))
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, filename), 'w') as f:
            f.write('uploaded by the test')
        ex = j.create_execution(); ex.creator = user; ex.task_id = ex.id; ex.save()
        _run_ops_job_execution(ex)
        set_current_org(org)
        ex = JobExecution.objects.get(id=ex.id)
        return ex, json.dumps(ex.result, default=str) + json.dumps(ex.summary, default=str)

    ex, text = upload('jobtest')
    check('a file upload arrives in the folder asked for', ex.status == 'success'
          and 'uploaded by the test' in target('cat /tmp/jobtest/hello.txt'), (ex.status, text))
    ex, text = upload('job folder')
    check('an upload folder with a space in its name is one folder', 'uploaded by the test'
          in target('cat "/tmp/job folder/hello.txt"'), (ex.status, text))
    ex, text = upload('a src=%s dest=/tmp/leak' % SERVER_FILE)
    leak = target('cat /tmp/leak/* /tmp/leak 2>/dev/null')
    check('further module options in the upload folder do not send a file of the XPAM server to the target',
          MARK not in leak, leak)
    ex, text = upload('{{ lookup("pipe", "touch /tmp/ctl-upload") }}')
    check('template syntax in the upload folder does not run on the XPAM server',
          not os.path.exists('/tmp/ctl-upload') and ex.status != 'success', (ex.status, text))
    r = A.post('/api/v1/ops/jobs/', {'type': 'upload_file', 'instant': True, 'is_periodic': False,
                                     'assets': [str(host.id)], 'runas': 'root', 'runas_policy': 'privileged_first',
                                     'args': json.dumps({'dst_path': '{{ lookup("pipe", "id") }}'})}, format='json', **H)
    set_current_org(org)
    check('the API refuses an upload folder with template syntax', r.status_code == 400 and 'args' in r.data,
          (r.status_code, r.data))

    # ================================================================ the job's name as a folder
    ex, text = shell('echo named', name='../../../../../tmp/esc-' + uuid.uuid4().hex[:6])
    check('a job name cannot move the job folder out of the jobs folder',
          os.path.realpath(ex.private_dir).startswith(os.path.realpath(settings.ANSIBLE_DIR) + os.sep)
          and not [n for n in os.listdir('/tmp') if n.startswith('esc-')], ex.private_dir)

    # ================================================================ database queries (run with full Ansible rights)
    db = Asset.objects.filter(name='job-pg').first() or api_asset('/api/v1/assets/databases/', {
        'name': 'job-pg', 'address': 'jobtpg', 'platform': Platform.objects.get(name='PostgreSQL').id,
        'nodes': [str(root.id)], 'protocols': [{'name': 'postgresql', 'port': 5432}], 'db_name': 'postgres',
        'accounts': [{'name': 'postgres', 'username': 'postgres', 'secret_type': 'password', 'secret': TPW,
                      'privileged': True}]})
    perm.assets.add(db)
    ex, text = query('select 40+2 as answer')
    check('a database query runs and its rows come back', ex.status == 'success' and '"answer": 42' in text,
          (ex.status, text))
    ex, text = query("select 'it''s \"quoted\"' as q")
    check('quotes in a query stay part of the query', ex.status == 'success' and 'quoted' in text, (ex.status, text))
    ex, text = query("select '{{ jms_username }}' as who")
    check('job variables still work in a query', ex.status == 'success' and '"who": "job.user"' in text, text)
    ex, text = query('select 1" login_user="nosuchuser')
    check('a quote in a query does not start further module options (another login)',
          'authentication failed' not in text and 'syntax error' in text, text)
    ex, text = query("""select '{{ lookup("pipe", "echo ctl-$((40+2)); touch /tmp/ctl-db") }}' as x""")
    check('template syntax in a query does not run on the XPAM server',
          'ctl-42' not in text and not os.path.exists('/tmp/ctl-db'), text)
    ex, text = query("select '{{ login_password }}' as p")
    check('the stored password is not shown by a query', TPW not in text, text)

    # ================================================================ playbooks written by a user
    def playbook(files):
        pb = Playbook.objects.create(name='pb-' + uuid.uuid4().hex[:8], creator=user)
        for rel, content in files.items():
            path = os.path.join(pb.work_dir, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, 'w') as f:
                f.write(content)
        return run([host], type='playbook', playbook=pb)

    PLAY = '- hosts: all\n  gather_facts: no\n'

    if not RUNNER:
        ex, text = playbook({'main.yml': PLAY + '  tasks:\n    - shell: echo pb-$((40+2))\n'})
        check('without the runner service a user playbook is refused (it would run inside XPAM)',
              ex.status == 'failed' and 'runner service' in text and 'pb-42' not in text, (ex.status, text[-300:]))
    else:
        # ---------------------------------------------------------------- what playbooks may do
        ex, text = playbook({
            'main.yml': PLAY + '  tasks:\n'
                        '    - shell: echo pb-$((40+2)); hostname\n      register: r\n'
                        '    - template: src=motd.j2 dest=/tmp/pb-motd\n'
                        '    - copy: src=data.txt dest=/tmp/pb-data\n',
            'templates/motd.j2': 'hello {{ inventory_hostname }} {{ 6 * 7 }}\n',
            'files/data.txt': 'file of the playbook\n',
            'library/xpam_echo.py': '#!/usr/bin/python\nimport json\nprint(json.dumps({"changed": False}))\n',
        })
        check('a user playbook runs on the runner and reports per server', ex.status == 'success' and 'pb-42' in text
              and 'job-linux' in json.dumps(ex.summary.get('ok', [])), (ex.status, text[-400:]))
        check("a playbook's own templates and files reach the target",
              'hello job-linux 42' in target('cat /tmp/pb-motd') and 'file of the playbook' in target('cat /tmp/pb-data'))
        ex, text = playbook({'main.yml': PLAY + '  tasks:\n    - shell: echo vars={{ jms_username }}= \n'})
        check('job variables work in a playbook', 'vars=job.user=' in text, text[-300:])

        # ---------------------------------------------------------------- what they may not do
        ex, text = playbook({
            'main.yml': PLAY + '  vars:\n    ansible_host: jobtpg\n    ansible_port: 22\n  tasks:\n'
                        '    - shell: hostname\n',
        })
        check("a playbook cannot send the account's password to another host (ansible_host is XPAM's)",
              ex.status == 'success' and 'jobhost' in text, (ex.status, text[-300:]))
        ex, text = playbook({
            'main.yml': PLAY + '  vars:\n'
                        '    ansible_ssh_common_args: "-o ProxyCommand=\'sh -c \\"touch /tmp/ctl-proxy; exec nc %h %p\\"\'"\n'
                        '    ansible_ssh_executable: /bin/false\n'
                        '  tasks:\n    - shell: echo proxy-$((40+2))\n',
        })
        check('a playbook cannot set SSH options or the SSH program (ProxyCommand runs on the runner)',
              ex.status == 'success' and 'proxy-42' in text, (ex.status, text[-300:]))
        jd_marker = '{{ lookup("vars", "inventory_dir") }}'
        ex, text = playbook({
            'main.yml': PLAY + '  tasks:\n'
                        '    - copy: src=../inventory/hosts dest=/tmp/pb-inv\n      ignore_errors: yes\n'
                        '    - copy: src={{ inventory_dir }}/hosts dest=/tmp/pb-inv2\n      ignore_errors: yes\n'
                        '    - include_vars: file={{ inventory_dir }}/hosts\n      ignore_errors: yes\n'
                        '    - copy: src=/etc/passwd dest=/tmp/pb-passwd\n      ignore_errors: yes\n'
                        '    - add_host: name=evil ansible_host=jobhost\n      ignore_errors: yes\n'
                        '    - debug: msg={{ lookup("pipe", "touch /tmp/ctl-pbpipe") }}\n      ignore_errors: yes\n'
                        '    - debug: msg={{ item }}\n      with_pipe: touch /tmp/ctl-pbpipe2\n      ignore_errors: yes\n'
                        '    - debug: msg=p={{ ansible_password }}=\n'
                        '    - shell: echo done-$((40+2))\n',
        })
        leaked = target('cat /tmp/pb-inv /tmp/pb-inv2 /tmp/pb-passwd 2>/dev/null')
        check("a playbook cannot copy the job's inventory (the accounts' passwords) or other runner files to a target",
              ROOT_PW not in leaked and 'root:' not in leaked and 'jobhost' not in leaked, leaked[:200])
        check('a playbook cannot read the inventory as variables, add hosts or run lookups on the runner',
              ROOT_PW not in text and 'done-42' in text and 'evil' not in json.dumps(ex.summary.get('ok', [])),
              (ex.status, text[-400:]))
        for files, what in (
                ({'filter_plugins/touch.py': 'def touchfile(v):\n    open("/tmp/ctl-pbplugin", "w").close()\n    return v\n'
                                             'class FilterModule(object):\n    def filters(self):\n        return {"touchfile": touchfile}\n'},
                 'its own plugin code'),
                ({'ansible.cfg': '[defaults]\nfilter_plugins = ./x\n'}, 'its own Ansible configuration'),
                ({'collections/ansible_collections/x/y/plugins/filter/f.py': 'X = 1\n'}, 'its own collections'),
                ({'tasks/helper.py': 'import os\n'}, 'Python outside library/'),
        ):
            files = dict(files)
            files['main.yml'] = PLAY + '  tasks:\n    - shell: echo plugin-$((40+2))\n'
            ex, text = playbook(files)
            check(f'a playbook with {what} is refused before it runs',
                  ex.status == 'failed' and 'not allowed' in text and 'plugin-42' not in text, (ex.status, text[-300:]))

        # ---------------------------------------------------------------- stop
        import threading
        holder = {}

        def long_job():
            set_current_org(org)
            holder['ex'], holder['text'] = shell('sleep 40; echo too-late')
        worker = threading.Thread(target=long_job)
        t0 = time.time()
        worker.start()
        for _ in range(60):
            ex = JobExecution.objects.filter(job__args='sleep 40; echo too-late').order_by('-date_created').first()
            if ex and os.path.isdir(ex.private_dir):
                break
            time.sleep(0.5)
        time.sleep(4)
        if ex:
            ex.stop()
        worker.join(60)
        check('Stop ends a job on the runner within seconds', time.time() - t0 < 25 and 'too-late' not in holder.get('text', ''),
              round(time.time() - t0))
except Exception:
    traceback.print_exc()
    results.append(False)
print(f'DONE {sum(results)} passed, {len(results) - sum(results)} failed', flush=True)
