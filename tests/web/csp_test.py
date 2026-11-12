"""The admin console under its Content-Security-Policy, in a real Chromium (Xvfb + DevTools, as the remote browser
runs it): each page loads without a single CSP violation (no inline script, no eval, nothing from another site),
the asset tree loads its nodes, and the console's live sockets connect.
  run with tests/web/csp_run.sh   (argv: base URL, session cookie name, session cookie value)"""
import json
import os
import subprocess
import sys
import time
import urllib.request

sys.path.insert(0, '/src')
import server  # (the remote browser's DevTools client)

BASE, COOKIE_NAME, COOKIE_VALUE = sys.argv[1:4]
PAGES = ['/web/#/console/dashboard', '/web/#/console/assets/assets', '/web/#/console/users/users',
         '/web/#/console/perms/asset-permissions', '/web/#/audit/dashboard', '/web/#/audit/sessions',
         '/web/#/workbench/', '/web/#/tickets/my-tickets', '/web/#/settings/basic', '/web/#/settings/security',
         '/web/#/settings/interface', '/web/#/settings/tools', '/web/#/profile/info']

display, port = 77, 9377
procs = [subprocess.Popen(['Xvfb', f':{display}', '-screen', '0', '1366x900x24', '-nolisten', 'tcp'],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)]
time.sleep(1.5)
env = dict(os.environ, DISPLAY=f':{display}', HOME='/tmp/csp-home')
procs.append(subprocess.Popen(['chromium', '--no-sandbox', '--no-first-run', '--disable-gpu', '--ignore-certificate-errors',
                               f'--remote-debugging-port={port}', '--user-data-dir=/tmp/csp-profile', 'about:blank'],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env))
for _ in range(50):
    try:
        targets = json.loads(urllib.request.urlopen(f'http://127.0.0.1:{port}/json', timeout=1).read())
        page = next(t for t in targets if t.get('type') == 'page')
        break
    except Exception:
        time.sleep(0.3)
cdp = server.CDP(page['webSocketDebuggerUrl'])
events = []
cdp.on_event = events.append
for domain in ('Page', 'Runtime', 'Log', 'Audits', 'Network'):
    cdp.call(f'{domain}.enable', {})
host = BASE.split('://', 1)[1].split('/')[0].split(':')[0]
cdp.call('Network.setCookie', {'name': COOKIE_NAME, 'value': COOKIE_VALUE, 'domain': host, 'path': '/',
                               'secure': BASE.startswith('https'), 'httpOnly': True})

results = []


def check(name, ok, detail=''):
    results.append(bool(ok))
    print(('PASS ' if ok else 'FAIL ') + name + (f'  [{str(detail)[:400]}]' if detail != '' else ''), flush=True)


def violations(evts):
    found = []
    for e in evts:
        m, p = e.get('method'), e.get('params', {})
        if m == 'Audits.issueAdded' and p.get('issue', {}).get('code') == 'ContentSecurityPolicyIssue':
            d = p['issue']['details'].get('contentSecurityPolicyIssueDetails', {})
            found.append(f"{d.get('violatedDirective')} {d.get('blockedURL', '')} {d.get('contentSecurityPolicyViolationType', '')}")
        elif m == 'Log.entryAdded' and 'Content Security Policy' in p.get('entry', {}).get('text', ''):
            found.append(p['entry']['text'][:200])
        elif m == 'Runtime.consoleAPICalled' and any('Content Security Policy' in str(a.get('value', ''))
                                                     for a in p.get('args', [])):
            found.append(str(p['args'][0].get('value'))[:200])
    return sorted(set(found))


def errors(evts):
    return sorted({(e['params'].get('exceptionDetails', {}).get('exception', {}) or {}).get('description', '')[:160]
                   for e in evts if e.get('method') == 'Runtime.exceptionThrown'})


all_violations = []
for path in PAGES:
    events.clear()
    cdp.call('Page.navigate', {'url': BASE + path})
    cdp.pump(7)
    v, errs = violations(events), errors(events)
    all_violations += v
    url = cdp.call('Runtime.evaluate', {'expression': 'location.href', 'returnByValue': True})['result'].get('value', '')
    signed_in = '/core/auth/login' not in url
    check(f'{path}: no CSP violation' + ('' if signed_in else ' (NOT SIGNED IN)'), not v and signed_in, v or url)
    if errs:
        print('     script errors:', errs[:3], flush=True)

# the asset tree loads its nodes (zTree, asked for JSON so it never evals)
events.clear()
cdp.call('Page.navigate', {'url': BASE + '/web/#/console/assets/assets'})
cdp.pump(8)
probe = ("JSON.stringify({li: document.querySelectorAll('.ztree li').length, "
         "ztree: [...document.querySelectorAll('[class*=ztree],[id*=ztree],[id*=Tree]')].map(e => e.tagName + '.' + e.className + '#' + e.id).slice(0, 6), "
         "nodes: [...document.querySelectorAll('[treenode], li[id*=_]')].length})")
info = json.loads(cdp.call('Runtime.evaluate', {'expression': probe, 'returnByValue': True})['result'].get('value', '{}'))
tree_requests = [e['params']['request']['url'] for e in events if e.get('method') == 'Network.requestWillBeSent'
                 and 'tree' in e['params']['request']['url']]
nodes = max(info.get('li', 0), info.get('nodes', 0))
check('the asset tree loads its nodes', nodes > 0, (info, tree_requests[:3], errors(events)[:2]))
ws = [e['params'].get('url', '') for e in events if e.get('method') == 'Network.webSocketCreated']
closed_bad = [e for e in events if e.get('method') == 'Network.webSocketFrameError']
check("the console's live sockets connect (connect-src 'self')", ws and not closed_bad, ws[:3])
check('no CSP violation on any page', not all_violations, sorted(set(all_violations))[:10])
for p in procs:
    p.terminate()
print(f'DONE {sum(results)}/{len(results)} passed', flush=True)
