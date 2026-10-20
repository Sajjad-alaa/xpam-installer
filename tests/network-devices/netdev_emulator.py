# Test tool: SSH command-line emulator of network devices (FortiGate, PAN-OS, Cisco IOS/ASA/NX-OS, Junos,
# Huawei, H3C) with a real local-user database, to test XPAM's network account automations.
# One port per vendor; the admin account is "admin" with the password in EMU_PASSWORD.
import hashlib, os, re, socket, sys, threading
import paramiko

PW = os.environ['EMU_PASSWORD']
HOSTKEY = paramiko.RSAKey.generate(2048)
PORTS = {2201: 'fortinet', 2202: 'paloalto', 2203: 'cisco_ios', 2204: 'cisco_asa', 2205: 'cisco_nxos',
         2206: 'juniper', 2207: 'huawei', 2208: 'h3c'}
LOG = os.environ.get('EMU_LOG') == '1'


def h(pw):
    return hashlib.sha256(pw.encode()).hexdigest()[:24]


class Device:
    hostname = 'dev'

    def __init__(self):
        self.users = {'admin': {'pw': h(PW), 'role': self.admin_role}}
        self.enable_pw = h(PW)
        self.lock = threading.Lock()

    def auth(self, username, password):
        u = self.users.get(username)
        return bool(u and u['pw'] == h(password))


class Shell:
    """One interactive session: echo, line handling, hidden input for passwords."""

    def __init__(self, dev, chan, user):
        self.dev, self.chan, self.user = dev, chan, user
        self.hidden = None  # callback for the next line, without echo

    def w(self, text):
        self.chan.send(text.replace('\n', '\r\n'))

    def run(self):
        self.w(self.banner())
        self.w(self.prompt())
        buf, last = '', ''
        while True:
            data = self.chan.recv(1024)
            if not data:
                return
            for ch in data.decode('utf-8', 'replace'):
                if ch == '\n' and last == '\r':
                    last = ch
                    continue
                last = ch
                if ch in '\r\n':
                    if self.hidden:
                        cb, self.hidden = self.hidden, None
                        self.w('\n')
                        out = cb(buf)
                    else:
                        self.w('\n')
                        if LOG:
                            print(type(self).__name__, repr(buf), flush=True)
                        with self.dev.lock:
                            out = self.handle(buf.strip())
                    buf = ''
                    if out is None:  # close
                        self.chan.close()
                        return
                    if out:
                        self.w(out if out.endswith('\n') else out + '\n')
                    if not self.hidden:
                        self.w(self.prompt())
                elif ch in '\x7f\x08':
                    buf = buf[:-1]
                else:
                    buf += ch
                    if not self.hidden:
                        self.chan.send(ch)

    def banner(self):
        return ''


# ------------------------------------------------------------------ FortiGate
class FortiDev(Device):
    admin_role = 'super_admin'

    def __init__(self):
        super().__init__()
        self.profiles = ['super_admin', 'prof_admin']


class FortiShell(Shell):
    def __init__(self, *a):
        super().__init__(*a)
        self.ctx, self.edit, self.output = [], None, 'more'

    def prompt(self):
        if self.edit:
            return 'FGT-XPAM (%s) # ' % self.edit
        if self.ctx:
            return 'FGT-XPAM (%s) # ' % self.ctx[-1].split()[-1]
        return 'FGT-XPAM # '

    def handle(self, line):
        d = self.dev
        if not line:
            return ''
        if line == 'get system status':
            return 'Version: FortiGate-VM64 v7.2.8,build1639,240313 (GA.M)\nVirtual domain configuration: disable\nHostname: FGT-XPAM'
        if line == 'get system status | grep Virtual':
            return 'Virtual domain configuration: disable'
        if line == 'get system status | grep Version':
            return 'Version: FortiGate-VM64 v7.2.8,build1639,240313 (GA.M)'
        if line == 'get system console':
            return 'output              : %s' % self.output
        if line == 'exit' and not self.ctx:
            return None
        if line == 'show system admin':
            out = ['config system admin']
            for name, u in d.users.items():
                out += ['    edit "%s"' % name, '        set accprofile "%s"' % u['role'], '        set vdom "root"',
                        '        set password ENC SH2%s' % u['pw'], '    next']
            return '\n'.join(out + ['end'])
        if line == 'show system accprofile':
            out = ['config system accprofile']
            for p in d.profiles:
                out += ['    edit "%s"' % p, '    next']
            return '\n'.join(out + ['end'])
        if line.startswith('config '):
            self.ctx.append(line[7:])
            return ''
        if line == 'end':
            self.ctx, self.edit = [], None
            return ''
        ctx = self.ctx[-1] if self.ctx else ''
        if line == 'next':
            if ctx == 'system admin' and self.edit and self.edit not in d.users:
                return ''
            self.edit = None
            return ''
        m = re.match(r'edit "?([^"]+?)"?$', line)
        if m and ctx in ('system admin', 'system accprofile'):
            self.edit = m.group(1)
            if ctx == 'system admin' and self.edit not in d.users:
                self.pending = {'pw': None, 'role': None}
            elif ctx == 'system accprofile' and self.edit not in d.profiles:
                d.profiles.append(self.edit)
            return ''
        m = re.match(r'delete "?([^"]+?)"?$', line)
        if m and ctx == 'system admin':
            if m.group(1) not in d.users:
                return 'entry not found in datasource\n\nvalue parse error before \'%s\'\nCommand fail. Return code -3' % m.group(1)
            del d.users[m.group(1)]
            return ''
        if ctx == 'system console' and line == 'set output standard':
            self.output = 'standard'
            return ''
        if ctx == 'system console' and line == 'set output more':
            self.output = 'more'
            return ''
        if ctx == 'system admin' and self.edit:
            u = d.users.get(self.edit)
            m = re.match(r'set accprofile "?([^"]+?)"?$', line)
            if m:
                if m.group(1) not in d.profiles:
                    return 'entry not found in datasource\n\nvalue parse error before \'%s\'\nCommand fail. Return code -3' % m.group(1)
                if u:
                    u['role'] = m.group(1)
                else:
                    self.pending['role'] = m.group(1)
                    self._maybe_create()
                return ''
            m = re.match(r'set password "([^"]*)"(?: "([^"]*)")?$', line)
            if m:
                if self.edit == self.user and u and (not m.group(2) or h(m.group(2)) != u['pw']):
                    return 'Please input old password correctly.\nCommand fail. Return code -1'
                if u:
                    u['pw'] = h(m.group(1))
                else:
                    self.pending['pw'] = h(m.group(1))
                    self._maybe_create()
                return ''
            if line.startswith('set vdom'):
                return ''
        if ctx == 'system accprofile' and self.edit and line.startswith('set '):
            return '' if line.split()[1] != 'wifi' else 'command parse error before \'wifi\'\nCommand fail. Return code -61'
        return 'Unknown action 0\nCommand fail. Return code -1' if not self.ctx else (
            'command parse error before \'%s\'\nCommand fail. Return code -61' % line.split()[0])

    def _maybe_create(self):
        if self.pending.get('pw') and self.pending.get('role'):
            self.dev.users[self.edit] = {'pw': self.pending['pw'], 'role': self.pending['role']}


# ------------------------------------------------------------------ PAN-OS
class PanDev(Device):
    admin_role = 'superuser'

    def __init__(self):
        super().__init__()
        self.candidate = None


class PanShell(Shell):
    def __init__(self, *a):
        super().__init__(*a)
        self.config, self.fmt = False, 'default'

    def prompt(self):
        return ('[edit]\nadmin@PA-VM# ' if self.config else 'admin@PA-VM> ').replace('admin', self.user, 1)

    def cand(self):
        d = self.dev
        if d.candidate is None:
            d.candidate = {k: dict(v) for k, v in d.users.items()}
        return d.candidate

    def handle(self, line):
        d = self.dev
        if not line:
            return ''
        if line == 'show system info' and not self.config:
            return 'hostname: PA-VM\nmodel: PA-VM\nsw-version: 10.2.4'
        if line in ('set cli scripting-mode on', 'set cli pager off', 'set cli terminal width 500'):
            return ''
        if line.startswith('set cli config-output-format '):
            self.fmt = line.split()[-1]
            return ''
        if line == 'show admins':
            return 'Admin            From            Client   Session-start    Idle-for\n' + \
                   '-' * 60 + '\n%-16s 10.0.0.1        CLI      10/20 10:00:00   00:00:00s' % self.user
        m = re.match(r'request password-hash password "?([^"]+?)"?$', line)
        if m and not self.config:
            return '$5$xpamsalt$' + h(m.group(1))
        if line == 'configure' and not self.config:
            self.config = True
            return 'Entering configuration mode'
        m = re.match(r'revert config partial admin (\S+)$', line)
        if m and self.config:
            d.candidate = None
            return 'Reverted the candidate configuration of admin ' + m.group(1)
        if line == 'exit':
            if self.config:
                self.config = False
                return ''
            return None
        if not self.config:
            return 'Unknown command: %s' % line.split()[0]
        c = self.cand()
        m = re.match(r'set mgt-config users (\S+) phash "?(\$5\$xpamsalt\$[0-9a-f]+)"?$', line)
        if m:
            c.setdefault(m.group(1), {'pw': None, 'role': None})['pw'] = m.group(2).split('$')[-1]
            return ''
        m = re.match(r'set mgt-config users (\S+) permissions role-based (superuser yes|superreader yes|'
                     r'deviceadmin localhost\.localdomain|devicereader localhost\.localdomain|custom profile \S+)$',
                     line)
        if m:
            c.setdefault(m.group(1), {'pw': None, 'role': None})['role'] = m.group(2).split()[0] if \
                not m.group(2).startswith('custom') else 'custom ' + m.group(2).split()[-1]
            return ''
        m = re.match(r'delete mgt-config users (\S+)( permissions)?$', line)
        if m:
            if m.group(2):
                if m.group(1) in c:
                    c[m.group(1)]['role'] = None
            else:
                c.pop(m.group(1), None)
            return ''
        if line == 'show mgt-config users':
            src = c
            out = []
            for name, u in src.items():
                out.append('set mgt-config users %s phash $5$xpamsalt$%s' % (name, u['pw']))
                if u['role']:
                    r = u['role']
                    r = ('custom profile ' + r.split()[1]) if r.startswith('custom') else (
                        r + (' yes' if r in ('superuser', 'superreader') else ' localhost.localdomain'))
                    out.append('set mgt-config users %s permissions role-based %s' % (name, r))
            return '\n'.join(out)
        m = re.match(r'commit( partial admin (\S+))?$', line)
        if m:
            if d.candidate is not None:
                for name, u in d.candidate.items():
                    if not u.get('pw') or not u.get('role'):
                        d.candidate = None
                        return 'Validation Error:\n mgt-config -> users -> %s is missing \'permissions\'\nCommit failed' % name
                d.users = d.candidate
                d.candidate = None
            return 'Commit job 7 is in progress. Use Ctrl+C to return to command prompt\n....55%....98%....100%\nConfiguration committed successfully'
        return 'Invalid syntax.'


# ------------------------------------------------------------------ Cisco IOS / ASA / NX-OS
class IOSDev(Device):
    admin_role = 15


class IOSShell(Shell):
    host = 'R1'
    version = 'Cisco IOS XE Software, Version 17.09.04a\nCisco IOS Software [Cupertino], Virtual XE Software'
    user_mode = True

    def __init__(self, *a):
        super().__init__(*a)
        self.enabled = not self.user_mode or self.dev.users[self.user]['role'] == 15
        self.config = False
        self.confirm = None

    def prompt(self):
        if self.config:
            return '%s(config)#' % self.host
        return self.host + ('#' if self.enabled else '>')

    def show_users(self):
        out = []
        for name, u in self.dev.users.items():
            priv = '' if u['role'] == 1 else ' privilege %d' % u['role']
            out.append('username %s%s secret 9 $9$%s' % (name, priv, u['pw']))
        return '\n'.join(out)

    def handle(self, line):
        d = self.dev
        if self.confirm:
            cb, self.confirm = self.confirm, None
            return cb(line)
        if not line:
            return ''
        if line in ('terminal width 511', 'terminal length 0', 'terminal pager 0'):
            return ''
        if line == 'enable':
            def check(pw):
                if h(pw) == d.enable_pw:
                    self.enabled = True
                    return ''
                return '% Access denied'
            self.hidden = check
            return 'Password: '
        if line == 'exit' and not self.config:
            return None
        if line == 'show version':
            return self.version
        if not self.enabled:
            return '% Invalid input detected at \'^\' marker.'
        if line in ('configure terminal', 'conf t'):
            self.config = True
            return 'Enter configuration commands, one per line.  End with CNTL/Z.'
        if line in ('end', 'exit') and self.config:
            self.config = False
            return ''
        if line.startswith('show running-config'):
            return self.show_users()
        if line == 'show version':
            return self.version
        if line in ('write mem', 'write memory'):
            return 'Building configuration...\n[OK]'
        if self.config:
            return self.config_line(line)
        return '% Invalid input detected at \'^\' marker.'

    def config_line(self, line):
        d = self.dev
        m = re.match(r'username (\S+) privilege (\d+) secret (\S+)$', line)
        if m:
            d.users[m.group(1)] = {'pw': h(m.group(3)), 'role': int(m.group(2))}
            return ''
        m = re.match(r'no username (\S+)$', line)
        if m:
            def do(answer):
                if answer.lower() in ('', 'y', 'yes'):
                    d.users.pop(m.group(1), None)
                return ''
            self.hidden = do  # waits for Enter, like IOS (no new prompt before the answer)
            return 'This operation will remove all username related configurations with same name.Do you want to continue? [confirm]'
        return '% Invalid input detected at \'^\' marker.'


class ASAShell(IOSShell):
    host = 'asa'
    version = 'Cisco Adaptive Security Appliance Software Version 9.18(3)'

    def __init__(self, *a):
        super().__init__(*a)
        self.enabled = False  # an ASA always starts in user mode

    def handle(self, line):
        if line == 'show curpriv':
            return 'Username : %s\nCurrent privilege level : %d' % (self.user, 15 if self.enabled else 1)
        return super().handle(line)

    def show_users(self):
        return '\n'.join('username %s password ***** pbkdf2 privilege %d' % (n, u['role'])
                         for n, u in self.dev.users.items())

    def config_line(self, line):
        d = self.dev
        if line == 'terminal width 511':
            return ''
        m = re.match(r'username (\S+) password (\S+) privilege (\d+)$', line)
        if m:
            d.users[m.group(1)] = {'pw': h(m.group(2)), 'role': int(m.group(3))}
            return ''
        m = re.match(r'no username (\S+)$', line)
        if m:
            d.users.pop(m.group(1), None)
            return ''
        return 'ERROR: % Invalid input detected at \'^\' marker.'


class NXDev(Device):
    admin_role = 'network-admin'


class NXShell(IOSShell):
    host = 'nx'
    version = 'Cisco Nexus Operating System (NX-OS) Software\nNXOS: version 10.3(3)'
    user_mode = False

    def show_users(self):
        out = []
        for n, u in self.dev.users.items():
            roles = u['role'] if isinstance(u['role'], list) else [u['role']]
            out.append('username %s password 5 $5$%s  role %s' % (n, u['pw'], roles[0]))
            out += ['username %s role %s' % (n, r) for r in roles[1:]]
        return '\n'.join(out)

    def handle(self, line):
        if line == 'copy running-config startup-config':
            return '[########################################] 100%\nCopy complete.'
        return super().handle(line)

    def config_line(self, line):
        d = self.dev
        m = re.match(r'username (\S+) password (\S+)(?: role (\S+))?$', line)
        if m:
            u = d.users.setdefault(m.group(1), {'pw': None, 'role': ['network-operator']})
            u['pw'] = h(m.group(2))
            roles = u['role'] if isinstance(u['role'], list) else [u['role']]
            if m.group(3) and m.group(3) not in roles:
                roles.append(m.group(3))
            u['role'] = roles
            return ''
        m = re.match(r'no username (\S+) role (\S+)$', line)
        if m and m.group(1) in d.users:
            roles = d.users[m.group(1)]['role']
            roles = roles if isinstance(roles, list) else [roles]
            d.users[m.group(1)]['role'] = [r for r in roles if r != m.group(2)]
            return ''
        m = re.match(r'no username (\S+)$', line)
        if m:
            d.users.pop(m.group(1), None)
            return ''
        return '% Invalid command at \'^\' marker.'


# ------------------------------------------------------------------ Junos
class JunosDev(Device):
    admin_role = 'super-user'

    def __init__(self):
        super().__init__()
        self.candidate = None


class JunosShell(Shell):
    def __init__(self, *a):
        super().__init__(*a)
        self.config = False

    def prompt(self):
        return ('\n[edit]\n%s@srx# ' if self.config else '%s@srx> ') % self.user

    def cand(self):
        if self.dev.candidate is None:
            self.dev.candidate = {k: dict(v) for k, v in self.dev.users.items()}
        return self.dev.candidate

    def handle(self, line):
        d = self.dev
        if not line:
            return ''
        if line == 'show version' and not self.config:
            return 'Hostname: srx\nModel: vsrx\nJunos: 22.4R1.10\nJUNOS Software Release [22.4R1.10]'
        if line == 'set cli screen-width 511':
            return 'Screen width set to 511'
        if line == 'set cli complete-on-space off':
            return 'Disabling complete-on-space'
        if line == 'set cli screen-length 0':
            return 'Screen length set to 0'
        if line == 'show configuration system login | display set':
            out = []
            for n, u in d.users.items():
                out += ['set system login user %s uid 2001' % n, 'set system login user %s class %s' % (n, u['role']),
                        'set system login user %s authentication encrypted-password "$6$%s"' % (n, u['pw'])]
            return '\n'.join(out)
        if line in ('configure', 'configure private'):
            self.config = True
            return ('warning: uncommitted changes will be discarded on exit\n' if line.endswith('private') else '') \
                + 'Entering configuration mode'
        if line in ('exit', 'exit configuration-mode'):
            if self.config:
                self.config = False
                return 'Exiting configuration mode'
            return None
        if not self.config:
            return 'error: unknown command: %s' % line.split()[0]
        c = self.cand()
        m = re.match(r'set system login user (\S+) class (\S+)$', line)
        if m:
            c.setdefault(m.group(1), {'pw': None, 'role': None})['role'] = m.group(2)
            return ''
        m = re.match(r'set system login user (\S+) authentication plain-text-password$', line)
        if m:
            name = m.group(1)

            def first(pw):
                def second(pw2):
                    if pw2 != pw:
                        return 'error: passwords do not match'
                    c.setdefault(name, {'pw': None, 'role': None})['pw'] = h(pw)
                    return ''
                self.hidden = second
                return 'Retype new password:'
            self.hidden = first
            return 'New password:'
        m = re.match(r'delete system login user (\S+)$', line)
        if m:
            c.pop(m.group(1), None)
            return ''
        if line == 'rollback 0':
            d.candidate = None
            return 'load complete'
        if line in ('commit', 'commit and-quit'):
            for n, u in c.items():
                if not u.get('role'):
                    return 'error: commit failed: (missing mandatory statements)\n[edit system login user %s]\n  \'class\' is missing' % n
            d.users, d.candidate = c, None
            if line == 'commit and-quit':
                self.config = False
                return 'commit complete\nExiting configuration mode'
            return 'commit complete'
        return 'syntax error.'


# ------------------------------------------------------------------ Huawei / H3C
class HuaweiDev(Device):
    admin_role = 15


class HuaweiShell(Shell):
    name = 'HUAWEI'

    def __init__(self, *a):
        super().__init__(*a)
        self.view = 'user'

    def prompt(self):
        return {'user': '<%s>', 'system': '[%s]', 'aaa': '[%s-aaa]'}[self.view] % self.name

    def handle(self, line):
        d = self.dev
        if not line:
            return ''
        if line == 'display version':
            return 'Huawei Versatile Routing Platform Software\nVRP (R) software, Version 8.180 (CE6800 V200R005C10SPC607B607)'
        if line == 'screen-length 0 temporary':
            return 'Info: The configuration takes effect on the current user terminal interface only.'
        if line == 'system-view':
            self.view = 'system'
            return 'Enter system view, return user view with Ctrl+Z.'
        if line == 'return':
            self.view = 'user'
            return ''
        if line == 'quit':
            if self.view == 'user':
                return None
            self.view = {'aaa': 'system', 'system': 'user'}[self.view]
            return ''
        if line == 'display current-configuration configuration aaa':
            out = ['#', 'aaa']
            for n, u in d.users.items():
                out += [' local-user %s password irreversible-cipher $1a$%s$' % (n, u['pw']),
                        ' local-user %s privilege level %d' % (n, u['role']),
                        ' local-user %s service-type terminal ssh' % n]
            return '\n'.join(out + ['#', 'return'])
        if line == 'save':
            def yes(answer):
                return 'Info: Save the configuration successfully.' if answer.lower().startswith('y') else ''
            self.hidden = yes
            return 'The current configuration will be written to the device. Are you sure to continue?[Y/N]'
        if self.view == 'aaa':
            m = re.match(r'local-user (\S+) password irreversible-cipher (\S+)$', line)
            if m:
                d.users.setdefault(m.group(1), {'pw': None, 'role': 0})['pw'] = h(m.group(2))
                return ''
            m = re.match(r'local-user (\S+) privilege level (\d+)$', line)
            if m and m.group(1) in d.users:
                d.users[m.group(1)]['role'] = int(m.group(2))
                return ''
            if re.match(r'local-user (\S+) service-type ssh terminal$', line):
                return ''
            m = re.match(r'undo local-user (\S+)$', line)
            if m:
                if m.group(1) not in d.users:
                    return 'Error: The user does not exist.'
                d.users.pop(m.group(1))
                return ''
        if line == 'aaa' and self.view == 'system':
            self.view = 'aaa'
            return ''
        if self.view == 'system' and re.match(r'(undo )?ssh user \S+( authentication-type password| service-type stelnet)?$', line):
            return ''
        return 'Error: Unrecognized command found at \'^\' position.'


class H3CDev(Device):
    admin_role = 'network-admin'


class H3CShell(Shell):
    name = 'H3C'

    def __init__(self, *a):
        super().__init__(*a)
        self.view, self.luser = 'user', None

    def prompt(self):
        if self.view == 'luser':
            return '[%s-luser-manage-%s]' % (self.name, self.luser)
        return ('<%s>' if self.view == 'user' else '[%s]') % self.name

    def handle(self, line):
        d = self.dev
        if not line:
            return ''
        if line == 'display version':
            return 'H3C Comware Software, Version 7.1.070, Release 6728P22'
        if line == 'screen-length disable':
            return ''
        if line == 'system-view':
            self.view = 'system'
            return 'System View: return to User View with Ctrl+Z.'
        if line == 'return':
            self.view = 'user'
            return ''
        if line == 'quit':
            if self.view == 'user':
                return None
            if self.view == 'luser':
                u = d.users.get(self.luser)
                if u is not None and u.get('pw') is None:
                    d.users.pop(self.luser)
            self.view = {'luser': 'system', 'system': 'user'}[self.view]
            return ''
        if line == 'display local-user':
            out = []
            for n, u in d.users.items():
                roles = ', '.join(u['role']) if isinstance(u['role'], list) else u['role']
                out += ['Device management user %s:' % n, '  State:                     Active',
                        '  Service type:              SSH/Terminal', '  Authorization attributes:',
                        '    Work directory:          flash:', '    User role list:          %s' % roles]
            return '\n'.join(out) + '\nTotal %d local users matched.' % len(d.users)
        if line == 'save force':
            return 'Validating file. Please wait...\nSaved the current configuration to mainboard device successfully.'
        if self.view == 'system':
            m = re.match(r'local-user (\S+) class manage$', line)
            if m:
                self.view, self.luser = 'luser', m.group(1)
                d.users.setdefault(m.group(1), {'pw': None, 'role': ['network-operator']})
                return 'New local user added.' if d.users[m.group(1)]['pw'] is None else ''
            m = re.match(r'undo local-user (\S+) class manage$', line)
            if m:
                d.users.pop(m.group(1), None)
                return ''
        if self.view == 'luser':
            u = d.users[self.luser]
            m = re.match(r'password simple (\S+)$', line)
            if m:
                u['pw'] = h(m.group(1))
                return ''
            if line == 'service-type ssh terminal':
                return ''
            m = re.match(r'undo authorization-attribute user-role (\S+)$', line)
            if m:
                roles = u['role'] if isinstance(u['role'], list) else [u['role']]
                u['role'] = [r for r in roles if r != m.group(1)]
                return ''
            m = re.match(r'authorization-attribute user-role (\S+)$', line)
            if m:
                roles = u['role'] if isinstance(u['role'], list) else [u['role']]
                if m.group(1) not in roles:
                    roles.append(m.group(1))
                u['role'] = roles
                return ''
        return '% Unrecognized command found at \'^\' position.'


DEVICES = {'fortinet': (FortiDev, FortiShell), 'paloalto': (PanDev, PanShell), 'cisco_ios': (IOSDev, IOSShell),
           'cisco_asa': (IOSDev, ASAShell), 'cisco_nxos': (NXDev, NXShell), 'juniper': (JunosDev, JunosShell),
           'huawei': (HuaweiDev, HuaweiShell), 'h3c': (H3CDev, H3CShell)}
STATE = {}


class Server(paramiko.ServerInterface):
    def __init__(self, dev):
        self.dev, self.user, self.event = dev, None, threading.Event()

    def check_auth_password(self, username, password):
        if self.dev.auth(username, password):
            self.user = username
            return paramiko.AUTH_SUCCESSFUL
        return paramiko.AUTH_FAILED

    def get_allowed_auths(self, username):
        return 'password,keyboard-interactive'

    def check_auth_interactive(self, username, submethods):
        self.pending_user = username
        return paramiko.InteractiveQuery('', '', ('Password: ', False))

    def check_auth_interactive_response(self, responses):
        if responses and self.dev.auth(self.pending_user, responses[0]):
            self.user = self.pending_user
            return paramiko.AUTH_SUCCESSFUL
        return paramiko.AUTH_FAILED

    def check_channel_request(self, kind, chanid):
        return paramiko.OPEN_SUCCEEDED if kind == 'session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_pty_request(self, *a):
        return True

    def check_channel_shell_request(self, channel):
        self.event.set()
        return True


def serve_client(sock, vendor):
    dev_cls, shell_cls = DEVICES[vendor]
    dev = STATE.setdefault(vendor, dev_cls())
    t = paramiko.Transport(sock, disabled_algorithms={'kex': ['diffie-hellman-group-exchange-sha256', 'diffie-hellman-group-exchange-sha1']})
    t.add_server_key(HOSTKEY)
    server = Server(dev)
    try:
        t.start_server(server=server)
        chan = t.accept(30)
        if chan is None:
            return
        server.event.wait(10)
        shell_cls(dev, chan, server.user).run()
    except Exception as e:
        if LOG:
            print('session error', vendor, repr(e), flush=True)
    finally:
        t.close()


def listen(port, vendor):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(('0.0.0.0', port))
    s.listen(20)
    while True:
        client, _ = s.accept()
        threading.Thread(target=serve_client, args=(client, vendor), daemon=True).start()


for port, vendor in PORTS.items():
    threading.Thread(target=listen, args=(port, vendor), daemon=True).start()
print('emulator ready', flush=True)
threading.Event().wait()
