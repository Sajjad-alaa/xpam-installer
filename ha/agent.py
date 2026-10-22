#!/usr/bin/env python3
"""
XPAM high availability agent (runs on each server, as the systemd service xpam-ha).

Patroni decides which server's PostgreSQL is the primary (with the other servers, and a witness when the
number of servers is even, voting in etcd). This agent makes the rest of XPAM follow that decision on its
own server. Active-passive (HA_TOPOLOGY, the default):

  primary  XPAM's services run, Redis is the main one, recordings and files are copied to the other
           servers every minute (rsync over SSH)
  standby  XPAM's services are stopped (the load balancer sees the server as down), Redis follows the
           primary's
  unknown  (Patroni unreachable for a while) XPAM's services are stopped: the database is not usable

Active-active: XPAM's services run on every server that is a healthy member of the cluster (primary or
standby) and has the leader's XPAM version (a rolling upgrade: the new version starts once the database has
it); its containers use the primary's database and the main Redis chosen by the Sentinels; every server
copies its new recordings and files to the others.

It also keeps the firewall rule that lets only the other servers and the witness reach the cluster ports,
and writes a status file the console shows (System settings -> High availability).
Only the Python standard library is used (the host's python3).
"""
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

INSTALLER = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG_FILE = os.environ.get('XPAM_CONFIG_FILE', '/opt/xpam/config/config.txt')
SECRETS_FILE = '/run/xpam/secrets/all.env'
INTERVAL = 2
STABLE_CHECKS = 2           # a role must be seen this many times in a row before acting (2 s apart)
UNKNOWN_GRACE = 30          # seconds without Patroni before the services are stopped
SYNC_EVERY = 60
HA_PORTS = '5432,8008,2379,2380,6379,6380,26380'
PEER_PORTS = '5432,8008,2379,2380,6380'
SENTINEL_PORT = '26380'
# (active-active: what every server copies to the others — not each server's own logs, task folders,
# built static files or start marker)
AA_SYNC_EXCLUDES = ['logs/', 'ha/', 'celery/', 'ansible/', 'static/', 'certs/', '.xpam-prepared', 'version.txt']
WITNESS_PORTS = '2379,2380'
CHAIN = 'XPAM-HA'


def log(*args):
    print(time.strftime('%Y-%m-%d %H:%M:%S'), *args, flush=True)


def read_config():
    conf = {}
    with open(CONFIG_FILE) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                k, v = line.split('=', 1)
                conf[k.strip()] = v.strip().strip('"').strip("'")
    # XPAM: secrets kept in Vault (xpamctl vault connect) are read into memory at boot: empty in config.txt
    try:
        with open(SECRETS_FILE) as f:
            for line in f:
                k, sep, v = line.rstrip('\n').partition('=')
                if sep and v and not conf.get(k):
                    conf[k] = v
    except OSError:
        pass
    return conf


def servers(conf):
    """ every XPAM server of the cluster (two-server clusters of earlier versions: this one and HA_PEER_IP) """
    listed = [s for s in conf.get('HA_SERVERS', '').split(',') if s]
    return listed or [s for s in (conf.get('HA_NODE_IP', ''), conf.get('HA_PEER_IP', '')) if s]


def peers(conf):
    return [s for s in servers(conf) if s != conf['HA_NODE_IP']]


def active_active(conf):
    return conf.get('HA_TOPOLOGY') == 'active-active'


def run(cmd, timeout=120, env=None):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)
        return p.returncode, (p.stdout + p.stderr).strip()
    except subprocess.TimeoutExpired:
        return 124, 'timeout'
    except OSError as e:
        return 127, str(e)


def tls_context(conf):
    """Client TLS with the cluster certificate (Patroni's API and etcd require it)."""
    import ssl
    certs = os.path.join((conf.get('CONFIG_DIR') or '/opt/xpam/config'), 'ha', 'certs')
    ctx = ssl.create_default_context(cafile=os.path.join(certs, 'ca.crt'))
    ctx.load_cert_chain(os.path.join(certs, 'node.crt'), os.path.join(certs, 'node.key'))
    return ctx


def patroni(conf, path, host=None, method='GET', body=None, auth=False, timeout=5):
    """(status, json) from a Patroni REST API (this server's unless host is given)."""
    import base64
    req = urllib.request.Request(f"https://{host or conf['HA_NODE_IP']}:8008/{path}", method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={'Content-Type': 'application/json'})
    if auth:
        token = base64.b64encode(f"patroni:{conf.get('HA_PATRONI_PASSWORD', '')}".encode()).decode()
        req.add_header('Authorization', f'Basic {token}')
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=tls_context(conf)) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw.strip().startswith(b'{') else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, {'message': raw.decode('utf-8', 'replace')[:200]}
    except Exception:
        return 0, {}


def patroni_role(conf):
    """'primary', 'standby' or 'unknown' (from this server's Patroni)."""
    code, data = patroni(conf, 'patroni', timeout=3)
    if code != 200:
        return 'unknown'
    role = data.get('role')
    if role in ('primary', 'master') and data.get('state') == 'running':
        return 'primary'
    if role in ('replica', 'standby_leader', 'sync_standby'):
        return 'standby'
    return 'unknown'


def app_running():
    code, out = run(['docker', 'ps', '--filter', 'name=^xpam_core$', '--filter', 'status=running', '-q'], 15)
    return code == 0 and bool(out)


def app(action):
    """Start/stop XPAM's services (not the database, Redis or etcd)."""
    code, out = run(['bash', os.path.join(INSTALLER, 'scripts', 'ha.sh'), f'app-{action}'], 900)
    if code:
        log(f'app-{action} failed:', out[-500:])
    return code == 0


def redis(conf, *args):
    env = dict(os.environ, REDISCLI_AUTH=conf.get('REDIS_PASSWORD', ''))
    return run(['docker', 'exec', '-e', 'REDISCLI_AUTH', 'xpam_redis', 'redis-cli', *args], 15, env=env)


def redis_follow(conf, primary):
    """primary=None: be the master; else follow that address."""
    code, info = redis(conf, 'INFO', 'replication')
    if code:
        return 'unreachable'
    is_master = 'role:master' in info
    if primary is None:
        if not is_master:
            redis(conf, 'REPLICAOF', 'NO', 'ONE')
            log('redis: now the master')
        return 'master'
    if is_master or f'master_host:{primary}' not in info:
        redis(conf, 'REPLICAOF', primary, '6380')  # (the TLS port: replication is encrypted)
        log(f'redis: following {primary}')
    return 'replica'


def sync_files(conf):
    """Copy recordings and files to the other servers. (ok, message)"""
    volume = (conf.get('VOLUME_DIR') or '/data/xpam')
    src = os.path.join(volume, 'core', 'data') + '/'
    key = os.path.join((conf.get('CONFIG_DIR') or '/opt/xpam/config'), 'ha', 'ssh', 'id_ed25519')
    known = os.path.join((conf.get('CONFIG_DIR') or '/opt/xpam/config'), 'ha', 'ssh', 'known_hosts')
    ssh = f'ssh -i {key} -o UserKnownHostsFile={known} -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10'
    if active_active(conf):
        opts = ['--update'] + [f'--exclude={x}' for x in AA_SYNC_EXCLUDES]
    else:
        opts = ['--exclude=logs/', '--exclude=ha/']
    errors = []
    for peer in peers(conf):
        code, out = run(['rsync', '-a', '--partial', '--timeout=120', *opts, '-e', ssh, src, f"root@{peer}:{src}"], 3600)
        if code:
            errors.append(f'{peer}: {out[-200:]}')
    return not errors, '; '.join(errors)[-300:]


def ensure_firewall(conf):
    """Who may reach THIS server's published cluster ports (Docker bypasses firewalld: the rules go into
    Docker's DOCKER-USER chain, which also exists before Docker starts):
      the other server  5432 (replication), 8008 (Patroni), 2379/2380 (vote), 6380 (Redis over TLS)
      the witness       2379/2380 (vote) only
      anybody else      nothing (also not 6379, Redis without TLS, which is never meant to be published)
    Only connections addressed to this server are checked; XPAM's own containers always pass."""
    run(['iptables', '-N', 'DOCKER-USER'], 10)
    run(['iptables', '-N', CHAIN], 10)
    run(['iptables', '-F', CHAIN], 10)
    peer_ports = PEER_PORTS + (f',{SENTINEL_PORT}' if active_active(conf) else '')
    rules = [['-i', 'br-+', '-j', 'RETURN'], ['-i', 'docker0', '-j', 'RETURN']]
    rules += [['-s', p, '-p', 'tcp', '-m', 'multiport', '--dports', peer_ports, '-j', 'RETURN'] for p in peers(conf)]
    if conf.get('HA_WITNESS_IP'):
        rules.append(['-s', conf['HA_WITNESS_IP'], '-p', 'tcp', '-m', 'multiport', '--dports', WITNESS_PORTS, '-j', 'RETURN'])
    rules.append(['-j', 'DROP'])
    for rule in rules:
        run(['iptables', '-A', CHAIN, *rule], 10)
    for old in (['DOCKER-USER', '!', '-i', 'br-+', '-p', 'tcp', '-m', 'multiport', '--dports', '5432,8008,2379,2380,6379',
                 '-j', CHAIN],
                ['DOCKER-USER', '-p', 'tcp', '-m', 'multiport', '--dports', '5432,8008,2379,2380,6379', '-m', 'conntrack',
                 '--ctorigdst', conf['HA_NODE_IP'], '-j', CHAIN]):
        while run(['iptables', '-D', *old], 10)[0] == 0:  # (rules of earlier versions)
            pass
    rule = ['DOCKER-USER', '-p', 'tcp', '-m', 'multiport', '--dports', HA_PORTS, '-m', 'conntrack',
            '--ctorigdst', conf['HA_NODE_IP'], '-j', CHAIN]
    if run(['iptables', '-C', *rule], 10)[0] != 0:
        code, out = run(['iptables', '-I', *rule], 10)
        if code:
            log('firewall rule could not be added:', out)


def peers_alive(conf):
    """Each other server's Patroni answers: {ip: True/False}."""
    return {p: patroni(conf, 'liveness', host=p, timeout=3)[0] != 0 for p in peers(conf)}


def witness_alive(conf):
    """The witness's vote answers its health check (mutual TLS with the cluster certificate); None: no witness."""
    if not conf.get('HA_WITNESS_IP'):
        return None
    try:
        with urllib.request.urlopen(f"https://{conf['HA_WITNESS_IP']}:2379/health", timeout=3,
                                    context=tls_context(conf)) as r:
            return json.loads(r.read()).get('health') in ('true', True)
    except Exception:
        return False


def vault_health(conf):
    """ XPAM's secrets are in Vault: each Vault server, as this server reaches it (its client certificate, TLS 1.3) """
    if conf.get('XPAM_SECRETS_FROM_VAULT') != '1':
        return None
    import ssl
    vdir = os.path.join((conf.get('CONFIG_DIR') or '/opt/xpam/config'), 'vault')
    try:
        env = dict(l.strip().split('=', 1) for l in open(os.path.join(vdir, 'vault.env')) if '=' in l)
        ctx = ssl.create_default_context(cafile=os.path.join(vdir, 'ca.crt'))
        ctx.minimum_version = ssl.TLSVersion.TLSv1_3
        ctx.load_cert_chain(os.path.join(vdir, 'client.crt'), os.path.join(vdir, 'client.key'))
    except Exception as e:
        return {'nodes': [], 'error': str(e)[:200]}
    nodes = []
    for addr in [a for a in env.get('VAULT_ADDRS', '').split(',') if a]:
        state = 'down'
        try:
            with urllib.request.urlopen(f'{addr}/v1/sys/health?standbyok=true&perfstandbyok=true',
                                        timeout=3, context=ctx) as r:
                state = 'ok' if r.status == 200 else 'sealed'
        except urllib.error.HTTPError as e:
            state = {503: 'sealed', 501: 'not initialized'}.get(e.code, f'error {e.code}')
        except Exception:
            state = 'down'
        nodes.append({'addr': addr, 'state': state})
    return {'nodes': nodes}


def iface_of(ip):
    code, out = run(['ip', '-o', '-4', 'addr', 'show'], 10)
    for line in out.splitlines():
        parts = line.split()
        if len(parts) > 3 and parts[3].split('/')[0] == ip:
            return parts[1]
    return ''


def floating_ip(conf, want):
    """Optional floating address (HA_VIP=10.0.0.100/24): held by the primary only."""
    vip = conf.get('HA_VIP', '')
    if not vip or '/' not in vip:
        return None
    dev = conf.get('HA_VIP_DEV') or iface_of(conf['HA_NODE_IP'])
    if not dev:
        return None
    address = vip.split('/')[0]
    code, out = run(['ip', '-o', '-4', 'addr', 'show', 'dev', dev], 10)
    has = f' {address}/' in out
    if want and not has:
        code, out = run(['ip', 'addr', 'add', vip, 'dev', dev], 10)
        if code == 0:
            log(f'floating address {vip} added on {dev}')
            run(['arping', '-U', '-c', '3', '-I', dev, address], 15)  # (tell the network it moved)
        else:
            log('floating address could not be added:', out)
    elif not want and has:
        run(['ip', 'addr', 'del', vip, 'dev', dev], 10)
        log(f'floating address {vip} removed')
    return want


def core_healthy():
    code, out = run(['docker', 'inspect', '-f', '{{.State.Health.Status}}', 'xpam_core'], 15)
    return code == 0 and out.strip() == 'healthy'


def notify_primary(conf, peer_ok):
    """Tell the administrators (site message, e-mail) that XPAM moved to this server."""
    code, out = run(['docker', 'exec', '-w', '/opt/jumpserver/apps', 'xpam_core', 'python', 'manage.py',
                     'xpam_ha_event', '--node', conf['HA_NODE_NAME'], '--ip', conf['HA_NODE_IP'],
                     '--peer', ','.join(peers(conf)), '--peer-reachable', '1' if peer_ok else '0'], 180)
    if code:
        log('administrators could not be notified yet:', out[-200:])
    return code == 0


def previous_role(conf):
    try:
        with open(os.path.join((conf.get('VOLUME_DIR') or '/data/xpam'), 'core', 'data', 'ha', 'status.json')) as f:
            return json.load(f).get('role')
    except (OSError, ValueError):
        return None


def cluster(conf):
    code, data = patroni(conf, 'cluster', timeout=3)
    if code != 200:
        return None
    return [{'name': m.get('name'), 'host': m.get('host'), 'role': m.get('role'), 'state': m.get('state'),
             'lag': m.get('lag'), 'timeline': m.get('timeline'),
             'version': (m.get('tags') or {}).get('xpam_version', ''),
             'server_id': (m.get('tags') or {}).get('xpam_server_id', '')} for m in data.get('members', [])]


def sentinel_master(conf):
    """ active-active: the main Redis as the Sentinels see it (this server's Sentinel), or None """
    env = dict(os.environ, REDISCLI_AUTH=conf.get('REDIS_PASSWORD', ''))
    code, out = run(['docker', 'exec', '-e', 'REDISCLI_AUTH', 'xpam_sentinel', 'redis-cli', '--tls', '-p', '26380',
                     '--cacert', '/tmp/xpam-tls/ca.crt', '--cert', '/tmp/xpam-tls/node.crt',
                     '--key', '/tmp/xpam-tls/node.key', 'SENTINEL', 'get-master-addr-by-name', 'xpam'], 15, env=env)
    lines = out.split() if code == 0 else []
    return lines[0] if lines else None


def redis_follow_sentinels(conf):
    """ active-active: the Sentinels move the main Redis; a Redis they do not know yet (a server that joined or
    came back empty) is pointed at the main one once, then they keep it """
    master = sentinel_master(conf)
    if not master:
        return 'no sentinel'
    if master == conf['HA_NODE_IP']:
        return 'master'
    code, info = redis(conf, 'INFO', 'replication')
    if code:
        return 'unreachable'
    if 'role:master' in info or f'master_host:{master}' not in info:
        redis(conf, 'REPLICAOF', master, '6380')
        log(f'redis: following {master} (named by the Sentinels)')
    return 'replica'


def same_version_as_leader(conf, members):
    """ active-active: this server runs the leader's XPAM version (during a rolling upgrade the servers of the
    other version wait, so that one version only uses the database) """
    mine = next((m for m in members or [] if m['name'] == conf['HA_NODE_NAME']), None)
    leader = next((m for m in members or [] if m['role'] in ('leader', 'standby_leader')), None)
    if not mine or not leader or not leader.get('version') or not mine.get('version'):
        return True  # (versions unknown: earlier versions did not report them)
    return mine['version'] == leader['version']


def handle_request(conf, members):
    """A switchover asked for in the console (the console has no access to the cluster itself)."""
    path = os.path.join((conf.get('VOLUME_DIR') or '/data/xpam'), 'core', 'data', 'ha', 'request.json')
    try:
        with open(path) as f:
            req = json.load(f)
        os.remove(path)
    except (OSError, ValueError):
        return None
    if req.get('action') != 'switchover' or time.time() - float(req.get('time') or 0) > 120:
        return {'action': 'switchover', 'ok': False, 'message': 'request expired', 'time': int(time.time())}
    leader = next((m['name'] for m in members or [] if m['role'] == 'leader'), None)
    candidate = next((m['name'] for m in members or [] if m['role'] == 'sync_standby' and m['state'] == 'streaming'), None)
    if leader != conf['HA_NODE_NAME'] or not candidate:
        return {'action': 'switchover', 'ok': False, 'message': 'no standby in sync', 'time': int(time.time())}
    code, data = patroni(conf, 'switchover', method='POST', auth=True, timeout=60,
                         body={'leader': leader, 'candidate': candidate})
    log(f"switchover to {candidate} asked by {req.get('by', '?')} in the console: HTTP {code}")
    return {'action': 'switchover', 'ok': code in (200, 202), 'message': str(data.get('message', ''))[:200],
            'by': req.get('by', ''), 'time': int(time.time())}


def write_status(conf, status):
    path = os.path.join((conf.get('VOLUME_DIR') or '/data/xpam'), 'core', 'data', 'ha')
    os.makedirs(path, exist_ok=True)
    tmp = os.path.join(path, '.status.json')
    with open(tmp, 'w') as f:
        json.dump(status, f)
    os.chmod(tmp, 0o644)
    os.replace(tmp, os.path.join(path, 'status.json'))


def main():
    conf = read_config()
    if conf.get('HA_ENABLED') != '1':
        log('high availability is not enabled in', CONFIG_FILE)
        return 1
    seen, count, acted = None, 0, None
    last_fw = last_probe = 0
    last_stable = previous_role(conf)   # (None on the first start after setup: no notice then)
    notify_pending = False
    reach = {'peer_reachable': None, 'witness_reachable': None, 'peers': {}}
    last_request = None
    unknown_since = None
    last_sync, sync = 0, {'ok': None, 'time': None, 'error': ''}
    log(f"agent started on {conf['HA_NODE_NAME']} ({conf['HA_NODE_IP']}), {conf.get('HA_TOPOLOGY') or 'active-passive'}, "
        f"other servers {','.join(peers(conf))}, witness {conf.get('HA_WITNESS_IP') or 'none'}")
    while True:
        try:
            conf = read_config()
            role = patroni_role(conf)
            count = count + 1 if role == seen else 1
            seen = role
            now = time.time()
            if role == 'unknown':
                unknown_since = unknown_since or now
            else:
                unknown_since = None

            if now - last_fw >= 60:
                ensure_firewall(conf)  # (Docker or a reboot may have recreated its chain)
                last_fw = now
            members = cluster(conf)
            if count >= STABLE_CHECKS and active_active(conf):
                if role in ('primary', 'standby'):
                    last_stable = role
                    floating_ip(conf, role == 'primary')
                    redis_follow_sentinels(conf)
                    if same_version_as_leader(conf, members):
                        if not app_running():
                            log(f'{role}: starting XPAM (active-active)')
                            app('start')
                    elif app_running():
                        log("the leader runs another XPAM version: stopping XPAM until this server has it")
                        app('stop')
                    if now - last_sync >= SYNC_EVERY:
                        ok, err = sync_files(conf)
                        last_sync = now
                        sync = {'ok': ok, 'time': int(now), 'error': err}
                        if not ok:
                            log('file copy to the other servers failed:', err)
                elif role == 'unknown' and unknown_since and now - unknown_since >= UNKNOWN_GRACE:
                    floating_ip(conf, False)
                    if app_running():
                        log(f'Patroni unreachable for {UNKNOWN_GRACE}s: stopping XPAM')
                        app('stop')
                if role != acted:
                    log(f'role: {role}')
                    acted = role
            elif count >= STABLE_CHECKS:
                if role == 'primary' and last_stable not in (None, 'primary'):
                    notify_pending = True  # failover or switchover to this server
                if role in ('primary', 'standby'):
                    last_stable = role
                if role == 'primary':
                    redis_follow(conf, None)
                    floating_ip(conf, True)
                    if not app_running():
                        log('primary: starting XPAM')
                        app('start')
                    if notify_pending and core_healthy():
                        notify_pending = not notify_primary(conf, reach.get('peer_reachable') is not False)
                    if now - last_sync >= SYNC_EVERY:
                        ok, err = sync_files(conf)
                        last_sync = now
                        sync = {'ok': ok, 'time': int(now), 'error': err}
                        if not ok:
                            log('file copy to the other servers failed:', err)
                elif role == 'standby':
                    floating_ip(conf, False)
                    notify_pending = False
                    if app_running():
                        log('standby: stopping XPAM')
                        app('stop')
                    leader = next((m for m in members or [] if m['role'] in ('leader', 'standby_leader')), None)
                    if leader and leader.get('host'):
                        redis_follow(conf, leader['host'])
                elif role == 'unknown' and unknown_since and now - unknown_since >= UNKNOWN_GRACE:
                    floating_ip(conf, False)
                    if app_running():
                        log(f'Patroni unreachable for {UNKNOWN_GRACE}s: stopping XPAM')
                        app('stop')
                if role != acted:
                    log(f'role: {role}')
                    acted = role

            if role == 'primary':
                result = handle_request(conf, members)
                if result:
                    last_request = result
            if now - last_probe >= 30:  # (not every loop: the other machines log each connection)
                alive = peers_alive(conf)
                reach = {'peer_reachable': all(alive.values()) if alive else None, 'peers': alive,
                         'witness_reachable': witness_alive(conf), 'vault': vault_health(conf)}
                last_probe = now
            write_status(conf, {
                'node': conf['HA_NODE_NAME'], 'node_ip': conf['HA_NODE_IP'], 'peer_ip': ','.join(peers(conf)),
                'servers': servers(conf), 'topology': conf.get('HA_TOPOLOGY') or 'active-passive',
                'witness_ip': conf.get('HA_WITNESS_IP', ''), 'role': role, 'app_running': app_running(),
                **reach, 'file_sync': sync, 'updated': int(now),
                'floating_ip': conf.get('HA_VIP', ''), 'members': members, 'request': last_request,
            })
        except Exception as e:  # never die: the service manager would restart us anyway
            log('error:', repr(e))
        time.sleep(INTERVAL)


if __name__ == '__main__':
    if sys.argv[1:] == ['firewall']:  # (xpam-ha-firewall.service: before Docker publishes any port)
        c = read_config()
        if c.get('HA_ENABLED') == '1':
            ensure_firewall(c)
        sys.exit(0)
    sys.exit(main())
