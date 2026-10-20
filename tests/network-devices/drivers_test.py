# Test: XPAM network device drivers against the emulator (every vendor, every operation)
import os, sys, time, traceback
sys.path.insert(0, '/work')
import paramiko
from network_device import session, DeviceError
PW = os.environ['EMU_PASSWORD']
HOST = 'netemu'
PORTS = {'fortinet': 2201, 'paloalto': 2202, 'cisco_ios': 2203, 'cisco_asa': 2204, 'cisco_nxos': 2205,
         'juniper': 2206, 'huawei': 2207, 'h3c': 2208}
results = []


def check(name, ok, detail=''):
    results.append(bool(ok))
    print(('PASS ' if ok else 'FAIL ') + name + (f'  [{detail}]' if detail != '' else ''), flush=True)


def login(port, user, pw):
    c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        c.connect(HOST, port=port, username=user, password=pw, timeout=10, look_for_keys=False, allow_agent=False)
        return True
    except Exception:
        return False
    finally:
        c.close()


only = sys.argv[1:] or list(PORTS)
for vendor in only:
    port = PORTS[vendor]
    print(f'== {vendor}', flush=True)
    t0 = time.time()
    try:
        with session(vendor, HOST, port, 'admin', PW, enable_password=PW) as dev:
            users = dev.list_users()
            check(f'{vendor}: list accounts', any(u['username'] == 'admin' and u['role'] == 'admin' for u in users), users)
            r = dev.push('xpam-ro', 'Ro-pass_1.x', 'read_only')
            u = dev.user('xpam-ro')
            check(f'{vendor}: push a read-only account', r == 'created' and u and u['role'] == 'read_only', u)
        check(f'{vendor}: the new account can sign in', login(port, 'xpam-ro', 'Ro-pass_1.x'))
        with session(vendor, HOST, port, 'admin', PW, enable_password=PW) as dev:
            dev.change('xpam-ro', 'Ro-pass_2.y')
            r = dev.push('xpam-ro', 'Ro-pass_3.z', 'admin')
            u = dev.user('xpam-ro')
            check(f'{vendor}: push again updates password and role', r == 'updated' and u and u['role'] == 'admin', u)
        check(f'{vendor}: old password refused, new one works', not login(port, 'xpam-ro', 'Ro-pass_2.y')
              and login(port, 'xpam-ro', 'Ro-pass_3.z'))
        with session(vendor, HOST, port, 'admin', PW, enable_password=PW) as dev:
            dev.push('xpam-ro', 'Ro-pass_4.w', 'read_only')
            u = dev.user('xpam-ro')
            check(f'{vendor}: role lowered back to read only', u and u['role'] == 'read_only', u)
        with session('auto', HOST, port, 'admin', PW, enable_password=PW) as dev:
            check(f'{vendor}: vendor recognised automatically', dev.vendor == vendor, dev.vendor)
        with session(vendor, HOST, port, 'admin', PW, enable_password=PW) as dev:
            for bad, label in (('bad pass', 'space'), ('a?b', 'question mark')):
                try:
                    dev.push('xpam-x', bad, 'read_only'); check(f'{vendor}: refuses a password with a {label}', False)
                except DeviceError as e:
                    check(f'{vendor}: refuses a password with a {label}', 'do not accept' in str(e))
            try:
                dev.remove('admin'); check(f'{vendor}: will not remove its own sign-in account', False)
            except DeviceError:
                check(f'{vendor}: will not remove its own sign-in account', True)
            check(f'{vendor}: remove the account', dev.remove('xpam-ro') and not dev.user('xpam-ro'))
            check(f'{vendor}: removing a missing account is not an error', dev.remove('xpam-ro') is False)
            try:
                dev.change('xpam-none', 'Abc-123.x'); check(f'{vendor}: change of a missing account fails', False)
            except DeviceError as e:
                check(f'{vendor}: change of a missing account fails', 'does not exist' in str(e))
        check(f'{vendor}: removed account cannot sign in', not login(port, 'xpam-ro', 'Ro-pass_4.w'))
    except Exception as e:
        traceback.print_exc()
        check(f'{vendor}: no unexpected error', False, repr(e)[:300])
    print(f'   ({time.time() - t0:.0f}s)')
print(f'RESULT: {sum(results)}/{len(results)} passed')
