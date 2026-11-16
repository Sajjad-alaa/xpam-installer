#!/usr/bin/env python3
"""XPAM runner: runs the jobs users write (commands, scripts, playbooks) away from core and its secrets.

The worker sends a job as ansible-runner's "transmit" stream (the job's inventory and project, packed) to
POST /run; the runner unpacks and runs it with `ansible-runner worker` under a user of its own for that job (one of
RUNNER_MAX_JOBS users, never two jobs at once), and streams the events back in the response. When the job ends,
fails, times out or the worker closes the connection (Stop), every process of that user is killed and the job's
folder removed. Nothing stays between jobs.

The container holds no XPAM secret except RUNNER_KEY (the worker's key for this service), has no database or Redis
access (its own network), a read-only file system and a memory limit. The runs are limited by the Ansible hardening
of the image (build/ansible_hardening.py): no code of the job runs here, the connection settings come from XPAM.

  GET  /health                     no key
  POST /run                        Authorization: Bearer <RUNNER_KEY>; X-Job-Dir: the job's folder (as in core)
"""
import hmac
import json
import os
import pwd
import re
import resource
import select
import shutil
import socket
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

KEY = os.environ.get('RUNNER_KEY', '')
PORT = int(os.environ.get('RUNNER_PORT', '8086'))
MAX_JOBS = int(os.environ.get('RUNNER_MAX_JOBS', '4'))
MAX_SECONDS = int(float(os.environ.get('RUNNER_MAX_HOURS', '6')) * 3600)
MAX_OUTPUT = int(os.environ.get('RUNNER_MAX_OUTPUT_MB', '200')) * 1024 * 1024
MAX_INPUT = int(os.environ.get('RUNNER_MAX_INPUT_MB', '200')) * 1024 * 1024
JOBS_ROOT = '/opt/core/data/share/ansible'
HOMES = '/tmp/home'   # (the job users' homes: on the runner's temporary file system)
# the job's folder is the one core uses, so the paths in its inventory (key files, upload sources) stay valid
JOB_DIR = re.compile(r'^/opt/core/data/share/ansible/[\w.-]{1,128}/[\w.-]{1,128}$')
ANSIBLE_RUNNER = '/opt/py3/bin/ansible-runner'
# what core may set for a job; everything else is dropped
ALLOWED_KWARGS = {
    'ident', 'inventory', 'playbook', 'module', 'module_args', 'host_pattern', 'limit', 'extravars', 'envvars',
    'timeout', 'verbosity', 'quiet', 'suppress_ansible_output', 'forks', 'cmdline', 'json_mode', 'rotate_artifacts',
}
ALLOWED_ENV = {'ANSIBLE_SUPER_MODE', 'XPAM_JOB_DIR', 'ANSIBLE_FORCE_COLOR', 'LC_ALL', 'LANG', 'ANSIBLE_TIMEOUT'}
# jobs with no user-written code (database queries, device commands: their text is passed as data) may need the
# full rights XPAM's own automations have; a playbook never
SUPER_MODE_MODULES = {'community.mysql.mysql_query', 'community.postgresql.postgresql_query', 'mssql_script',
                      'ce_command', 'oracle_query'}

slots = {}            # slot number -> job dir
slots_lock = threading.Lock()


def log(*parts):
    print(time.strftime('%Y-%m-%d %H:%M:%S'), *parts, file=sys.stderr, flush=True)


def slot_user(n):
    return pwd.getpwnam('runner%d' % n)


def take_slot(job_dir):
    with slots_lock:
        if job_dir in slots.values():
            return None
        for n in range(1, MAX_JOBS + 1):
            if n not in slots:
                slots[n] = job_dir
                return n
    return None


def kill_user(uid):
    """Every process of the slot's user, until none is left."""
    for _ in range(50):
        found = False
        for entry in os.listdir('/proc'):
            if not entry.isdigit():
                continue
            try:
                if os.stat('/proc/' + entry).st_uid == uid:
                    found = True
                    os.kill(int(entry), signal.SIGKILL)
            except (FileNotFoundError, ProcessLookupError, PermissionError):
                continue
        if not found:
            return
        time.sleep(0.1)


def empty_as(user, folder):
    """Removes a folder of the job's user: its content as that user (root here has no right to read it), then the
    empty folder itself as root (the owner of the folder above)."""
    if not os.path.lexists(folder):
        return
    subprocess.run(['/usr/bin/setpriv', '--reuid=%d' % user.pw_uid, '--regid=%d' % user.pw_gid, '--clear-groups',
                    'find', folder, '-xdev', '-mindepth', '1', '-delete'],
                   check=False, timeout=300, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.rmdir(folder)


def make_for(user, folder):
    os.mkdir(folder, 0o700)
    os.chown(folder, user.pw_uid, user.pw_gid)


def release_slot(n, job_dir, user):
    kill_user(user.pw_uid)
    for folder in (job_dir, user.pw_dir):
        try:
            empty_as(user, folder)
        except OSError as e:
            log('could not remove', folder, e)
    try:
        os.rmdir(os.path.dirname(job_dir))
    except OSError:
        pass
    with slots_lock:
        slots.pop(n, None)


def clean_kwargs(line):
    """The job's settings (the stream's first line), limited to what a job may set."""
    data = json.loads(line)
    kwargs = data.get('kwargs')
    if not isinstance(kwargs, dict):
        raise ValueError('the stream does not start with the job settings')
    kwargs = {k: v for k, v in kwargs.items() if k in ALLOWED_KWARGS}
    env = kwargs.get('envvars') or {}
    if not isinstance(env, dict):
        raise ValueError('envvars')
    env = {k: str(v) for k, v in env.items() if k in ALLOWED_ENV}
    if env.get('ANSIBLE_SUPER_MODE') and (kwargs.get('playbook') or kwargs.get('module') not in SUPER_MODE_MODULES):
        env.pop('ANSIBLE_SUPER_MODE')
    kwargs['envvars'] = env
    return (json.dumps({'kwargs': kwargs}) + '\n').encode()


def limits(user):
    def apply():
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        resource.setrlimit(resource.RLIMIT_NPROC, (512, 512))
        resource.setrlimit(resource.RLIMIT_FSIZE, (512 * 1024 * 1024, 512 * 1024 * 1024))
        resource.setrlimit(resource.RLIMIT_NOFILE, (4096, 4096))
    return apply


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.0'   # the response is the event stream, ended by closing the connection
    server_version = 'xpam-runner'
    sys_version = ''

    def log_message(self, fmt, *args):
        log(self.address_string(), fmt % args)

    def reply(self, code, text):
        body = (json.dumps({'error': text}) + '\n').encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == '/health':
            with slots_lock:
                busy = len(slots)
            body = json.dumps({'ok': True, 'jobs': busy, 'max_jobs': MAX_JOBS}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.reply(404, 'not found')

    def do_POST(self):
        if self.path != '/run':
            return self.reply(404, 'not found')
        given = self.headers.get('Authorization', '')
        if not hmac.compare_digest(given.encode(), ('Bearer ' + KEY).encode()):
            return self.reply(401, 'unauthorized')
        job_dir = self.headers.get('X-Job-Dir', '')
        if not JOB_DIR.match(job_dir) or '/../' in job_dir or job_dir.endswith('/..'):
            return self.reply(400, 'invalid job folder')
        try:
            length = int(self.headers.get('Content-Length', ''))
        except ValueError:
            return self.reply(411, 'length required')
        if length <= 0 or length > MAX_INPUT:
            return self.reply(413, 'the job is too large')
        n = take_slot(job_dir)
        if n is None:
            return self.reply(429, 'the runner is busy, try again')
        user = slot_user(n)
        started = time.monotonic()
        proc = None
        try:
            os.makedirs(os.path.dirname(job_dir), mode=0o711, exist_ok=True)
            if os.path.lexists(job_dir):
                raise ValueError('the job folder exists already')
            make_for(user, job_dir)
            # (its home: Ansible's temporary files when a module runs here; emptied after every job)
            if os.path.lexists(user.pw_dir):
                empty_as(user, user.pw_dir)
            make_for(user, user.pw_dir)
            first = self.rfile.readline(min(length, 16 * 1024 * 1024))
            first_clean = clean_kwargs(first)
            env = {
                'PATH': '/opt/py3/bin:/usr/local/bin:/usr/bin:/bin', 'HOME': job_dir, 'TMPDIR': job_dir,
                'LC_ALL': 'C.UTF-8', 'LANG': 'C.UTF-8', 'ANSIBLE_CONFIG': '/opt/runner/ansible.cfg',
                'ANSIBLE_LOCAL_TEMP': os.path.join(job_dir, '.ansible-tmp'), 'XPAM_JOB_DIR': job_dir,
                'ANSIBLE_RUNNER_KEEPALIVE_SECONDS': '20', 'PYTHONDONTWRITEBYTECODE': '1',
            }
            proc = subprocess.Popen(
                [ANSIBLE_RUNNER, 'worker', '--private-data-dir', job_dir],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, cwd='/',
                user=user.pw_uid, group=user.pw_gid, extra_groups=[], start_new_session=True,
                preexec_fn=limits(user), close_fds=True)
        except Exception as e:
            log('job not started:', job_dir, e)
            release_slot(n, job_dir, user)
            return self.reply(400, 'the job could not be started: %s' % e)
        log('job started:', job_dir, 'as', user.pw_name)

        def feed():
            try:
                proc.stdin.write(first_clean)
                remaining = length - len(first)
                while remaining > 0:
                    chunk = self.rfile.read(min(remaining, 1024 * 1024))
                    if not chunk:
                        break
                    proc.stdin.write(chunk)
                    remaining -= len(chunk)
            except (BrokenPipeError, OSError):
                pass
            finally:
                try:
                    proc.stdin.close()
                except OSError:
                    pass

        feeder = threading.Thread(target=feed, daemon=True)
        feeder.start()

        def deadline():
            # the time limit, and Stop: the worker closes the connection (it sends nothing after the job, so the
            # connection turning readable means it was closed)
            conn = self.connection
            while proc.poll() is None:
                if time.monotonic() - started > MAX_SECONDS:
                    log('job over its time limit:', job_dir)
                    kill_user(user.pw_uid)
                    return
                if not feeder.is_alive():
                    try:
                        readable, _, _ = select.select([conn], [], [], 1)
                        if readable and not conn.recv(1, socket.MSG_PEEK):
                            log('job stopped by the worker:', job_dir)
                            kill_user(user.pw_uid)
                            return
                    except OSError:
                        kill_user(user.pw_uid)
                        return
                else:
                    time.sleep(1)

        threading.Thread(target=deadline, daemon=True).start()
        sent = 0
        reason = 'finished'
        try:
            self.send_response(200)
            self.send_header('Content-Type', 'application/x-ndjson')
            self.end_headers()
            while True:
                line = proc.stdout.readline()
                if not line:
                    break
                sent += len(line)
                if sent > MAX_OUTPUT:
                    reason = 'output limit'
                    self.wfile.write((json.dumps({'status': 'failed', 'job_explanation':
                                                  'The job produced more output than the runner allows.'}) + '\n'
                                      + json.dumps({'eof': True}) + '\n').encode())
                    break
                self.wfile.write(line)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            reason = 'stopped by the worker'
        finally:
            release_slot(n, job_dir, user)
            log('job ended (%s):' % reason, job_dir, 'after %ds' % (time.monotonic() - started))


def main():
    if len(KEY) < 24:
        sys.exit('RUNNER_KEY is not set (at least 24 characters)')
    if os.geteuid() != 0:
        sys.exit('the runner starts as root to run each job as its own user')
    for n in range(1, MAX_JOBS + 1):
        slot_user(n)  # (fails at start if the image has fewer job users)
    os.makedirs(JOBS_ROOT, mode=0o711, exist_ok=True)
    os.chmod(JOBS_ROOT, 0o711)
    os.makedirs(HOMES, mode=0o711, exist_ok=True)
    os.chmod(HOMES, 0o711)
    for name in os.listdir(JOBS_ROOT):   # (left over by a restart: nothing runs any more)
        shutil.rmtree(os.path.join(JOBS_ROOT, name), ignore_errors=True)
    server = ThreadingHTTPServer(('0.0.0.0', PORT), Handler)
    server.daemon_threads = True
    log('XPAM runner on port %d, up to %d jobs at once' % (PORT, MAX_JOBS))
    server.serve_forever()


if __name__ == '__main__':
    main()
