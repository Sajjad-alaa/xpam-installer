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
import socket
import subprocess
import sys
import time
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


def tcp_open(host, port, timeout=2):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def ensure_firewall(conf):
    """Only the other server and the witness may reach the replication ports (published by Docker,
    which bypasses firewalld: the rule goes into Docker's DOCKER-USER chain)."""
    allowed = [conf['HA_PEER_IP'], conf['HA_WITNESS_IP']]
    run(['iptables', '-N', CHAIN], 10)
    run(['iptables', '-F', CHAIN], 10)
    for ip in allowed:
        run(['iptables', '-A', CHAIN, '-s', ip, '-j', 'RETURN'], 10)
    run(['iptables', '-A', CHAIN, '-j', 'DROP'], 10)
    rule = ['DOCKER-USER', '!', '-i', 'br-+', '-p', 'tcp', '-m', 'multiport', '--dports', HA_PORTS, '-j', CHAIN]
    if run(['iptables', '-C', *rule], 10)[0] != 0:
        code, out = run(['iptables', '-I', *rule], 10)
        if code:
            log('firewall rule could not be added:', out)


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
    last_fw = 0
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
                if role == 'primary':
                    redis_follow(conf, None)
                    if not app_running():
                        log('primary: starting XPAM')
                        app('start')
                    if now - last_sync >= SYNC_EVERY:
                        ok, err = sync_files(conf)
                        last_sync = now
                        sync = {'ok': ok, 'time': int(now), 'error': err}
                        if not ok:
                            log('file copy to the other server failed:', err)
                elif role == 'standby':
                    if app_running():
                        log('standby: stopping XPAM')
                        app('stop')
                    redis_follow(conf, conf['HA_PEER_IP'])
                elif role == 'unknown' and unknown_since and now - unknown_since >= UNKNOWN_GRACE and app_running():
                    log(f'Patroni unreachable for {UNKNOWN_GRACE}s: stopping XPAM')
                    app('stop')
                if role != acted:
                    log(f'role: {role}')
                    acted = role

            write_status(conf, {
                'node': conf['HA_NODE_NAME'], 'node_ip': conf['HA_NODE_IP'], 'peer_ip': conf['HA_PEER_IP'],
                'witness_ip': conf['HA_WITNESS_IP'], 'role': role, 'app_running': app_running(),
                'peer_reachable': tcp_open(conf['HA_PEER_IP'], 8008),
                'witness_reachable': tcp_open(conf['HA_WITNESS_IP'], 2379),
                'file_sync': sync, 'updated': int(now),
            })
        except Exception as e:  # never die: the service manager would restart us anyway
            log('error:', repr(e))
        time.sleep(INTERVAL)


if __name__ == '__main__':
    sys.exit(main())
