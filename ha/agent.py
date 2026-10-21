#!/usr/bin/env python3
"""
XPAM high availability agent (runs on each server, as the systemd service xpam-ha).

Patroni decides which server's PostgreSQL is the primary (with the other server and the witness voting
in etcd). This agent makes the rest of XPAM follow that decision on its own server:

  primary  XPAM's services run, Redis is the master, recordings and files are copied to the other
           server every minute (rsync over SSH)
  standby  XPAM's services are stopped (the load balancer sees the server as down), Redis follows the
           primary's
  unknown  (Patroni unreachable for a while) XPAM's services are stopped: the database is not usable

It also keeps the firewall rule that lets only the other server and the witness reach the replication
ports, and writes a status file the console shows (System settings -> High availability).
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
INTERVAL = 3
STABLE_CHECKS = 2           # a role must be seen this many times in a row before acting
UNKNOWN_GRACE = 30          # seconds without Patroni before the services are stopped
SYNC_EVERY = 60
HA_PORTS = '5432,8008,2379,2380,6379'
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
    return conf


def run(cmd, timeout=120, env=None):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)
        return p.returncode, (p.stdout + p.stderr).strip()
    except subprocess.TimeoutExpired:
        return 124, 'timeout'
    except OSError as e:
        return 127, str(e)


def patroni_role(conf):
    """'primary', 'standby' or 'unknown' (from this server's Patroni)."""
    try:
        with urllib.request.urlopen(f"http://{conf['HA_NODE_IP']}:8008/patroni", timeout=3) as r:
            data = json.loads(r.read())
    except Exception:
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
        redis(conf, 'CONFIG', 'SET', 'masterauth', conf.get('REDIS_PASSWORD', ''))
        redis(conf, 'REPLICAOF', primary, '6379')
        log(f'redis: following {primary}')
    return 'replica'


def sync_files(conf):
    """Copy recordings and files to the other server. (ok, message)"""
    volume = conf.get('VOLUME_DIR', '/data/xpam')
    src = os.path.join(volume, 'core', 'data') + '/'
    key = os.path.join(conf.get('CONFIG_DIR', '/opt/xpam/config'), 'ha', 'ssh', 'id_ed25519')
    known = os.path.join(conf.get('CONFIG_DIR', '/opt/xpam/config'), 'ha', 'ssh', 'known_hosts')
    ssh = f'ssh -i {key} -o UserKnownHostsFile={known} -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10'
    code, out = run(['rsync', '-a', '--partial', '--timeout=120', '--exclude=logs/', '--exclude=ha/',
                     '-e', ssh, src, f"root@{conf['HA_PEER_IP']}:{src}"], 3600)
    return code == 0, (out[-300:] if code else '')


def ensure_firewall(conf):
    """Only the other server and the witness may reach the replication ports of THIS server (published by
    Docker, which bypasses firewalld: the rule goes into Docker's DOCKER-USER chain). It matches only
    connections addressed to this server, so the containers' own outgoing connections are never touched."""
    run(['iptables', '-N', CHAIN], 10)
    run(['iptables', '-F', CHAIN], 10)
    for rule in (['-i', 'br-+', '-j', 'RETURN'], ['-i', 'docker0', '-j', 'RETURN'],
                 ['-s', conf['HA_PEER_IP'], '-j', 'RETURN'], ['-s', conf['HA_WITNESS_IP'], '-j', 'RETURN'],
                 ['-j', 'DROP']):
        run(['iptables', '-A', CHAIN, *rule], 10)
    # (the first version matched by interface: remove it)
    old = ['DOCKER-USER', '!', '-i', 'br-+', '-p', 'tcp', '-m', 'multiport', '--dports', HA_PORTS, '-j', CHAIN]
    while run(['iptables', '-D', *old], 10)[0] == 0:
        pass
    rule = ['DOCKER-USER', '-p', 'tcp', '-m', 'multiport', '--dports', HA_PORTS, '-m', 'conntrack',
            '--ctorigdst', conf['HA_NODE_IP'], '-j', CHAIN]
    if run(['iptables', '-C', *rule], 10)[0] != 0:
        code, out = run(['iptables', '-I', *rule], 10)
        if code:
            log('firewall rule could not be added:', out)


def peer_alive(conf):
    """The other server's Patroni answers (no authentication needed for /liveness)."""
    try:
        with urllib.request.urlopen(f"http://{conf['HA_PEER_IP']}:8008/liveness", timeout=3):
            return True
    except urllib.error.HTTPError:
        return True  # (answers, even if not healthy)
    except Exception:
        return False


def witness_alive(conf):
    """The witness's vote answers its health check (mutual TLS with the cluster certificate)."""
    import ssl
    certs = os.path.join(conf.get('CONFIG_DIR', '/opt/xpam/config'), 'ha', 'certs')
    try:
        ctx = ssl.create_default_context(cafile=os.path.join(certs, 'ca.crt'))
        ctx.load_cert_chain(os.path.join(certs, 'node.crt'), os.path.join(certs, 'node.key'))
        with urllib.request.urlopen(f"https://{conf['HA_WITNESS_IP']}:2379/health", timeout=3, context=ctx) as r:
            return json.loads(r.read()).get('health') in ('true', True)
    except Exception:
        return False


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
                     '--peer', conf['HA_PEER_IP'], '--peer-reachable', '1' if peer_ok else '0'], 180)
    if code:
        log('administrators could not be notified yet:', out[-200:])
    return code == 0


def previous_role(conf):
    try:
        with open(os.path.join(conf.get('VOLUME_DIR', '/data/xpam'), 'core', 'data', 'ha', 'status.json')) as f:
            return json.load(f).get('role')
    except (OSError, ValueError):
        return None


def write_status(conf, status):
    path = os.path.join(conf.get('VOLUME_DIR', '/data/xpam'), 'core', 'data', 'ha')
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
    reach = {'peer_reachable': None, 'witness_reachable': None}
    unknown_since = None
    last_sync, sync = 0, {'ok': None, 'time': None, 'error': ''}
    log(f"agent started on {conf['HA_NODE_NAME']} ({conf['HA_NODE_IP']}), peer {conf['HA_PEER_IP']}, "
        f"witness {conf['HA_WITNESS_IP']}")
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
            if count >= STABLE_CHECKS:
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
                            log('file copy to the other server failed:', err)
                elif role == 'standby':
                    floating_ip(conf, False)
                    notify_pending = False
                    if app_running():
                        log('standby: stopping XPAM')
                        app('stop')
                    redis_follow(conf, conf['HA_PEER_IP'])
                elif role == 'unknown' and unknown_since and now - unknown_since >= UNKNOWN_GRACE:
                    floating_ip(conf, False)
                    if app_running():
                        log(f'Patroni unreachable for {UNKNOWN_GRACE}s: stopping XPAM')
                        app('stop')
                if role != acted:
                    log(f'role: {role}')
                    acted = role

            if now - last_probe >= 30:  # (not every loop: the other machines log each connection)
                reach = {'peer_reachable': peer_alive(conf), 'witness_reachable': witness_alive(conf)}
                last_probe = now
            write_status(conf, {
                'node': conf['HA_NODE_NAME'], 'node_ip': conf['HA_NODE_IP'], 'peer_ip': conf['HA_PEER_IP'],
                'witness_ip': conf['HA_WITNESS_IP'], 'role': role, 'app_running': app_running(),
                **reach, 'file_sync': sync, 'updated': int(now),
                'floating_ip': conf.get('HA_VIP', ''),
            })
        except Exception as e:  # never die: the service manager would restart us anyway
            log('error:', repr(e))
        time.sleep(INTERVAL)


if __name__ == '__main__':
    sys.exit(main())
