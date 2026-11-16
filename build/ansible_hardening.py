#!/usr/bin/env python3
"""XPAM: limits for Ansible runs started on behalf of a user (job centre: commands, playbooks, file upload).

The core image installs stock ansible-core (security updates) in place of the upstream product's patched copy, so the
limits that copy carried are applied here, at build time, to the installed package -- and extended, because the
upstream ones can be bypassed (`lookup('ansible.builtin.pipe', ...)`, `lookup('lines', ...)`, `with_pipe:`).

A run is a *user run* unless the environment has ANSIBLE_SUPER_MODE (set only by XPAM's own automations:
ops/ansible/runner.py). In a user run:
  * templates are rendered in Jinja's sandbox (no attribute walking to Python internals);
  * only lookups that read nothing from the server may be used (no pipe/lines/file/template/env/url/...), whether
    called as lookup()/query() or as `with_<name>:`;
  * variables whose name says they hold a secret are masked for templating (`{{ ansible_password }}` gives
    ********); the connection itself still gets the real values;
  * only network connections to the targets are allowed (ssh, paramiko, winrm, psrp, network devices): no `local`,
    no chroot/docker/... connection, and no implicit `localhost` host.

The script fails (and so does the image build) if a place it patches is not found exactly once: a new ansible-core
version must be checked by hand.
  ansible_hardening.py <site-packages>/ansible          apply
  ansible_hardening.py --check <path-to>/ansible        run the installed ansible both ways and fail unless a user
                                                        run is refused and a run of the automations is not
"""
import os
import pathlib
import subprocess
import sys
import tempfile

GUARD = '''# XPAM: limits for Ansible runs started on behalf of a user (see build/ansible_hardening.py in the installer).
import os
from collections.abc import Mapping

from ansible.errors import AnsibleError

SHADOW = '********'
SENSITIVE_WORDS = ('password', 'secret', 'token', 'key', 'passphrase', 'become_pass', 'private')
# lookups that only rearrange the data they are given, or read the (masked) variables
SAFE_LOOKUPS = frozenset((
    'dict', 'indexed_items', 'inventory_hostnames', 'items', 'list', 'nested', 'random_choice', 'sequence',
    'subelements', 'together', 'varnames', 'vars',
))
# connections that go to the target over the network
SAFE_CONNECTIONS = frozenset((
    'ssh', 'smart', 'paramiko', 'paramiko_ssh', 'winrm', 'psrp',
    'network_cli', 'netconf', 'httpapi',
    'ansible.netcommon.network_cli', 'ansible.netcommon.netconf', 'ansible.netcommon.httpapi',
))
LOCAL_NAMES = frozenset(('localhost', '127.0.0.1', '::1'))


def user_run():
    return not os.environ.get('ANSIBLE_SUPER_MODE')


def _short(name):
    name = str(name)
    for prefix in ('ansible.builtin.', 'ansible.legacy.'):
        if name.startswith(prefix):
            return name[len(prefix):]
    return name


def check_lookup(name):
    if user_run() and _short(name) not in SAFE_LOOKUPS:
        raise AnsibleError("The lookup `%s` is disabled" % name)


def check_connection(name):
    if user_run() and _short(name) not in SAFE_CONNECTIONS:
        raise AnsibleError("The connection `%s` is disabled" % name)


def _is_sensitive(key):
    key = key.lower()
    return key.startswith('js_') or any(word in key for word in SENSITIVE_WORDS)


def _clean(key, value):
    if isinstance(key, str) and _is_sensitive(key):
        return SHADOW
    if isinstance(value, Mapping):
        return {k: _clean(k, v) for k, v in value.items()}
    return value


def clean_sensitive_vars(variables):
    """The variables a user's template may read: secrets masked."""
    if not user_run():
        return variables
    return {k: _clean(k, v) for k, v in variables.items()}


# --- how a task connects comes from XPAM's inventory only. A playbook could otherwise send the account's password
# to a host of its choice (ansible_host), or run a command on this server through an SSH option (ProxyCommand in
# ansible_ssh_common_args, ansible_ssh_executable, ...). Variables set by the playbook (vars, set_fact, vars files,
# group_vars next to the playbook) are replaced by the inventory's value for that host, or removed.
import re
CONNECTION_VAR = re.compile(
    r'^ansible_(host|port|user|password|pass|connection|private_key_file|host_key_checking|network_os'
    r'|(ssh|sshpass|scp|sftp|paramiko|winrm|psrp|httpapi|netconf|network_cli|libssh|persistent|remote|connection)_\w+'
    r'|(?!shell_|become_)\w+_(executable|exe))$')


def _inventory_vars(host):
    if host is None:
        return {}
    from ansible.inventory.helpers import get_group_vars
    from ansible.utils.vars import combine_vars
    return combine_vars(get_group_vars(host.get_groups()), host.vars or {})


def _pin(variables, inventory, masked):
    for key in [k for k in variables if isinstance(k, str) and CONNECTION_VAR.match(k)]:
        if key in inventory:
            variables[key] = _clean(key, inventory[key]) if masked else inventory[key]
        else:
            variables.pop(key)


def pin_connection_vars(variables, host, masked=False, inventory_manager=None):
    """In a user run: the connection variables of the task's host, and of each host it delegates to, as the
    inventory has them."""
    if not user_run():
        return
    _pin(variables, _inventory_vars(host), masked)
    delegated = variables.get('ansible_delegated_vars')
    if isinstance(delegated, dict):
        for name, dvars in delegated.items():
            if isinstance(dvars, dict):
                target = inventory_manager.get_host(name) if inventory_manager is not None else None
                _pin(dvars, _inventory_vars(target), masked)


# --- actions that change the inventory (a host the playbook defines would carry its own connection settings)
REFUSED_ACTIONS = frozenset(('add_host',))


def check_action(name):
    if user_run() and _short(name) in REFUSED_ACTIONS:
        raise AnsibleError("The action `%s` is disabled" % name)


# --- files of this server a user run may read (copy/template/script sources, vars files): only the job's own
# folder (XPAM_JOB_DIR, set by XPAM for every job), never the parts holding the secrets -- the inventory (with the
# accounts' passwords and key files), the runner's settings, the results. Reading them is refused once the
# inventory is parsed (Ansible itself reads it first).
_state = {'inventory_parsed': False}
SECRET_PARTS = ('inventory', 'env', 'artifacts')


def inventory_parsed():
    _state['inventory_parsed'] = True


def _job_dir():
    job_dir = os.environ.get('XPAM_JOB_DIR')
    return os.path.realpath(job_dir) if job_dir else None


def _inside(path, folder):
    return path == folder or path.startswith(folder.rstrip(os.sep) + os.sep)


def check_read(path):
    """Any file read through Ansible's loader in a user run."""
    if not user_run() or not _state['inventory_parsed'] or not path:
        return
    job_dir = _job_dir()
    real = os.path.realpath(os.fsdecode(path))
    if job_dir and any(_inside(real, os.path.join(job_dir, part)) for part in SECRET_PARTS):
        raise AnsibleError('This file cannot be read: %s' % os.fsdecode(path))


def check_source(path):
    """A local source file of an action (copy, template, script, unarchive...): inside the job's folder."""
    if not user_run():
        return
    job_dir = _job_dir()
    real = os.path.realpath(os.fsdecode(path))
    if not job_dir or not _inside(real, job_dir) \
            or any(_inside(real, os.path.join(job_dir, part)) for part in SECRET_PARTS):
        raise AnsibleError('Only files of the job can be used as a source: %s' % os.fsdecode(path))


# --- plugins (Python code that runs on this server) only from the installation, never from the playbook's folders.
# Modules and module_utils run on the targets and may come with the playbook.
PLAYBOOK_PLUGIN_DIRS = frozenset(('library', 'module_utils'))


def plugin_dir_allowed(subdir):
    return not user_run() or subdir in PLAYBOOK_PLUGIN_DIRS
'''

# (file, text to find exactly once, replacement)
PATCHES = [
    # --- templates: sandbox for user runs; lookups limited
    ('template/__init__.py',
     'from jinja2.nativetypes import NativeEnvironment\n',
     "import os as _xpam_os\n"
     "if _xpam_os.environ.get('ANSIBLE_SUPER_MODE'):\n"
     "    from jinja2.nativetypes import NativeEnvironment\n"
     "else:\n"
     "    from jinja2.sandbox import SandboxedEnvironment as NativeEnvironment\n"
     "from ansible import xpam_guard as _xpam_guard\n"),
    ('template/__init__.py',
     "    def _lookup(self, name, /, *args, **kwargs):\n"
     "        instance = lookup_loader.get(name, loader=self._loader, templar=self)\n",
     "    def _lookup(self, name, /, *args, **kwargs):\n"
     "        _xpam_guard.check_lookup(name)\n"
     "        instance = lookup_loader.get(name, loader=self._loader, templar=self)\n"),
    # (the sandbox refuses `__class__`; the same test through a filter)
    ('playbook/conditional.py',
     "{{{{ [true if __cres else false, __cres.__class__.__name__] }}}}')",
     "{{{{ [true if __cres else false, __cres | ansible.builtin.type_debug] }}}}')"),
    # --- `with_<lookup>:` loops load the lookup without the templar
    ('executor/task_executor.py',
     "                mylookup = self._shared_loader_obj.lookup_loader.get(self._task.loop_with, loader=self._loader, templar=templar)\n",
     "                _xpam_guard.check_lookup(self._task.loop_with)\n"
     "                mylookup = self._shared_loader_obj.lookup_loader.get(self._task.loop_with, loader=self._loader, templar=templar)\n"),
    ('vars/manager.py',
     "                    mylookup = lookup_loader.get(task.loop_with, loader=self._loader, templar=templar)\n",
     "                    _xpam_guard.check_lookup(task.loop_with)\n"
     "                    mylookup = lookup_loader.get(task.loop_with, loader=self._loader, templar=templar)\n"),
    ('vars/manager.py',
     "from ansible.plugins.loader import lookup_loader\n",
     "from ansible.plugins.loader import lookup_loader\n"
     "from ansible import xpam_guard as _xpam_guard\n"),
    # --- secrets masked for templating; the connection keeps the real values
    ('executor/task_executor.py',
     "from ansible.utils.vars import combine_vars\n",
     "from ansible.utils.vars import combine_vars\n"
     "from ansible import xpam_guard as _xpam_guard\n"),
    ('executor/task_executor.py',
     "            variables = self._job_vars\n"
     "\n"
     "        templar = Templar(loader=self._loader, variables=variables)\n",
     "            variables = self._job_vars\n"
     "\n"
     "        origin_vars = variables.copy()\n"
     "        variables = _xpam_guard.clean_sensitive_vars(variables)\n"
     "        templar = Templar(loader=self._loader, variables=variables)\n"),
    ('executor/task_executor.py',
     "            cvars = variables.get('ansible_delegated_vars', {}).get(self._task.delegate_to, {})\n"
     "        else:\n"
     "            # just use normal host vars\n"
     "            cvars = variables\n",
     "            cvars = origin_vars.get('ansible_delegated_vars', {}).get(self._task.delegate_to, {})\n"
     "        else:\n"
     "            # just use normal host vars\n"
     "            cvars = origin_vars\n"),
    # --- connections: only to the targets, over the network
    ('executor/task_executor.py',
     "        conn_type = self._play_context.connection\n"
     "\n"
     "        connection, plugin_load_context = self._shared_loader_obj.connection_loader.get_with_context(\n",
     "        conn_type = self._play_context.connection\n"
     "        _xpam_guard.check_connection(conn_type)\n"
     "\n"
     "        connection, plugin_load_context = self._shared_loader_obj.connection_loader.get_with_context(\n"),
    ('plugins/connection/local.py',
     "        super(Connection, self).__init__(*args, **kwargs)\n"
     "        self.cwd = None\n",
     "        super(Connection, self).__init__(*args, **kwargs)\n"
     "        self.cwd = None\n"
     "        if not os.environ.get('ANSIBLE_SUPER_MODE'):\n"
     "            raise AnsibleError('Local connection is disabled')\n"),
    # --- no implicit localhost, and no host named so, in a user run
    ('inventory/data.py',
     "            matching_host = self._create_implicit_localhost(hostname)\n",
     "            if not _xpam_guard.user_run():\n"
     "                matching_host = self._create_implicit_localhost(hostname)\n"),
    ('inventory/data.py',
     "from ansible import constants as C\n",
     "from ansible import constants as C\n"
     "from ansible import xpam_guard as _xpam_guard\n"),
    ('inventory/manager.py',
     "from ansible import constants as C\n",
     "from ansible import constants as C\n"
     "from ansible import xpam_guard as _xpam_guard\n"),
    ('inventory/manager.py',
     "                    raise AnsibleOptionsError(\"Invalid 'order' specified for inventory hosts: %s\" % order)\n"
     "\n"
     "        return hosts\n",
     "                    raise AnsibleOptionsError(\"Invalid 'order' specified for inventory hosts: %s\" % order)\n"
     "\n"
     "        if _xpam_guard.user_run():\n"
     "            hosts = [h for h in hosts if h.name not in _xpam_guard.LOCAL_NAMES]\n"
     "\n"
     "        return hosts\n"),
]

NEEDS_OS = ('plugins/connection/local.py',)

PATCHES += [
    # connection variables pinned to the inventory (the masked copy for templates, the real one for the connection)
    ('executor/task_executor.py',
     "        origin_vars = variables.copy()\n"
     "        variables = _xpam_guard.clean_sensitive_vars(variables)\n",
     "        _xpam_guard.check_action(self._task.action)\n"
     "        origin_vars = variables.copy()\n"
     "        _xpam_guard.pin_connection_vars(origin_vars, self._host, inventory_manager=self._variable_manager._inventory)\n"
     "        variables = _xpam_guard.clean_sensitive_vars(variables)\n"
     "        _xpam_guard.pin_connection_vars(variables, self._host, masked=True, inventory_manager=self._variable_manager._inventory)\n"),
    ('executor/task_executor.py',
     "        self._calculate_delegate_to(templar, variables)\n",
     "        self._calculate_delegate_to(templar, variables)\n"
     "        _xpam_guard.pin_connection_vars(variables, self._host, masked=True, inventory_manager=self._variable_manager._inventory)\n"),
    # the inventory is parsed: from now on its files are off limits for a user run
    ('inventory/manager.py',
     "        for host in self.hosts.values():\n"
     "            host.vars = combine_vars(host.vars, get_vars_from_inventory_sources(self._loader, self._sources, [host], 'inventory'))\n",
     "        for host in self.hosts.values():\n"
     "            host.vars = combine_vars(host.vars, get_vars_from_inventory_sources(self._loader, self._sources, [host], 'inventory'))\n"
     "        _xpam_guard.inventory_parsed()\n"),
    ('parsing/dataloader.py',
     "        b_file_name = to_bytes(self.path_dwim(file_name))\n"
     "        # This is what we really want but have to fix unittests to make it pass\n",
     "        b_file_name = to_bytes(self.path_dwim(file_name))\n"
     "        _xpam_guard.check_read(b_file_name)\n"
     "        # This is what we really want but have to fix unittests to make it pass\n"),
    ('parsing/dataloader.py',
     "        real_path = self.path_dwim(file_path)\n"
     "\n"
     "        try:\n"
     "            if decrypt:\n",
     "        real_path = self.path_dwim(file_path)\n"
     "        _xpam_guard.check_read(real_path)\n"
     "\n"
     "        try:\n"
     "            if decrypt:\n"),
    ('parsing/dataloader.py',
     "from ansible.errors import AnsibleFileNotFound, AnsibleParserError\n",
     "from ansible.errors import AnsibleFileNotFound, AnsibleParserError\n"
     "from ansible import xpam_guard as _xpam_guard\n"),
    # local sources of actions
    ('plugins/action/__init__.py',
     "        # if missing it will return a file not found exception\n"
     "        return self._loader.path_dwim_relative_stack(path_stack, dirname, needle)\n",
     "        # if missing it will return a file not found exception\n"
     "        found = self._loader.path_dwim_relative_stack(path_stack, dirname, needle)\n"
     "        _xpam_guard.check_source(found)\n"
     "        return found\n"),
    ('plugins/action/__init__.py',
     "from ansible import constants as C\n",
     "from ansible import constants as C\n"
     "from ansible import xpam_guard as _xpam_guard\n"),
    # plugins from the playbook's folders, collections next to the playbook
    ('plugins/loader.py',
     "        directory = os.path.realpath(directory)\n"
     "\n"
     "        if directory is not None:\n"
     "            if with_subdir:\n",
     "        directory = os.path.realpath(directory)\n"
     "        if not _xpam_guard.plugin_dir_allowed(self.subdir):\n"
     "            return\n"
     "\n"
     "        if directory is not None:\n"
     "            if with_subdir:\n"),
    ('plugins/loader.py',
     "from ansible import constants as C\n",
     "from ansible import constants as C\n"
     "from ansible import xpam_guard as _xpam_guard\n"),
    ('cli/playbook.py',
     "            AnsibleCollectionConfig.playbook_paths = b_playbook_dirs\n",
     "            if not _xpam_guard.user_run():\n"
     "                AnsibleCollectionConfig.playbook_paths = b_playbook_dirs\n"),
    ('cli/playbook.py',
     "from ansible import constants as C\n",
     "from ansible import constants as C\n"
     "from ansible import xpam_guard as _xpam_guard\n"),
]


def check(ansible):
    """The result, tried: what a user run must not do, and what the automations must still do."""
    marker = 'marker-$((40+2))'          # the shell that runs it prints marker-42; the text itself never does
    secret = 'build-check-secret'
    with tempfile.TemporaryDirectory() as tmp:
        inventory = os.path.join(tmp, 'inv.yml')
        with open(inventory, 'w') as f:
            f.write('all:\n  hosts:\n    h1:\n      ansible_host: 127.0.0.1\n      ansible_password: %s\n' % secret)

        def run(args, super_mode=False):
            env = dict(os.environ, LC_ALL='C.UTF-8', HOME=tmp, ANSIBLE_LOCAL_TEMP=os.path.join(tmp, 'a'))
            env.pop('ANSIBLE_SUPER_MODE', None)
            if super_mode:
                env['ANSIBLE_SUPER_MODE'] = '1'
            done = subprocess.run([ansible, '-i', inventory, 'all'] + args, env=env, cwd=tmp, text=True,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=300)
            return done.stdout

        def debug(expression):
            return ['-m', 'debug', '-a', 'msg={{ %s }}' % expression]

        refused = [
            ('lookup pipe', debug('lookup("pipe", "echo %s")' % marker), 'marker-42'),
            ('lookup ansible.builtin.pipe', debug('lookup("ansible.builtin.pipe", "echo %s")' % marker), 'marker-42'),
            ('lookup lines', debug('lookup("lines", "echo %s")' % marker), 'marker-42'),
            ('query pipe', debug('query("pipe", "echo %s")' % marker), 'marker-42'),
            ('a secret variable', debug('ansible_password'), secret),
            ('a secret through the vars lookup', debug('lookup("vars", "ansible_password")'), secret),
            ('the local connection', ['-c', 'local', '-m', 'shell', '-a', 'echo %s' % marker], 'marker-42'),
            ('the chroot connection', ['-c', 'community.general.chroot', '-m', 'shell', '-a', 'echo %s' % marker],
             'marker-42'),
        ]
        for name, args, forbidden in refused:
            out = run(args)
            if forbidden in out:
                sys.exit('ansible_hardening: %s is not refused in a user run:\n%s' % (name, out[-600:]))
        allowed = [
            ('lookups', debug('lookup("pipe", "echo %s")' % marker), 'marker-42'),
            ('secret variables', debug('ansible_password'), secret),
            ('the local connection', ['-c', 'local', '-m', 'shell', '-a', 'echo %s' % marker], 'marker-42'),
        ]
        for name, args, expected in allowed:
            out = run(args, super_mode=True)
            if expected not in out:
                sys.exit('ansible_hardening: the automations (super mode) lost %s:\n%s' % (name, out[-600:]))
    print('ansible_hardening: checked (%d refused in a user run, %d kept for the automations)'
          % (len(refused), len(allowed)))


def main():
    if len(sys.argv) == 3 and sys.argv[1] == '--check':
        return check(sys.argv[2])
    root = pathlib.Path(sys.argv[1])
    release = (root / 'release.py').read_text()
    if "__version__ = '2.16." not in release:
        sys.exit('ansible_hardening: written for ansible-core 2.16.x; check the patches against this version')
    if (root / 'xpam_guard.py').exists():
        sys.exit('ansible_hardening: already applied')
    for name in NEEDS_OS:
        text = (root / name).read_text()
        if '\nimport os\n' not in text:
            sys.exit('ansible_hardening: %s does not import os' % name)
    for name, old, new in PATCHES:
        path = root / name
        text = path.read_text()
        if text.count(old) != 1:
            sys.exit('ansible_hardening: %s: expected the text once, found %d times:\n%s' % (name, text.count(old), old))
        path.write_text(text.replace(old, new))
    (root / 'xpam_guard.py').write_text(GUARD)
    for cache in root.rglob('__pycache__'):
        for pyc in cache.glob('*.pyc'):
            pyc.unlink()
    print('ansible_hardening: %d patches applied to %s' % (len(PATCHES), root))


if __name__ == '__main__':
    main()
