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
version must be checked by hand. Run:  ansible_hardening.py <site-packages>/ansible
"""
import pathlib
import sys

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


def main():
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
