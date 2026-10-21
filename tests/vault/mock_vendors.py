"""
Mock servers for the vault backends that cannot run here, following each vendor's documented REST API:
  Delinea Secret Server  (port 8301): /oauth2/token (password grant), /api/v1/secrets[...]
  Google Secret Manager  (port 8302): /token (JWT bearer, RS256 signature checked with the service account's
                                      public key), /v1/projects/{p}/secrets[...]
Every API call without a valid token is refused (401). State is in memory; /_state shows it (test only).
  python3 mock_vendors.py <gcp-public-key.pem> <delinea-user> <delinea-password>
"""
import base64
import json
import re
import secrets
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import jwt

GCP_PUBLIC_KEY = open(sys.argv[1]).read()
DELINEA_USER, DELINEA_PASSWORD = sys.argv[2], sys.argv[3]
FOLDER_ID, TEMPLATE_ID = 7, 6003

lock = threading.Lock()
delinea = {'tokens': set(), 'secrets': {}, 'next': 100, 'calls': 0}
gcp = {'tokens': set(), 'secrets': {}, 'calls': 0}


class Base(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def body(self):
        n = int(self.headers.get('Content-Length') or 0)
        return self.rfile.read(n) if n else b''

    def send(self, code, data=None, raw=None, ctype='application/json'):
        payload = raw if raw is not None else (json.dumps(data).encode() if data is not None else b'')
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def bearer(self, store):
        auth = self.headers.get('Authorization', '')
        return auth.startswith('Bearer ') and auth[7:] in store['tokens']


class Delinea(Base):
    def handle_any(self, method):
        url = urlparse(self.path)
        if url.path == '/_state':
            return self.send(200, {k: v for k, v in delinea.items() if k != 'tokens'})
        if url.path == '/oauth2/token' and method == 'POST':
            form = parse_qs(self.body().decode())
            if form.get('grant_type') == ['password'] and form.get('username') == [DELINEA_USER] \
                    and form.get('password') == [DELINEA_PASSWORD]:
                token = secrets.token_hex(16)
                delinea['tokens'].add(token)
                return self.send(200, {'access_token': token, 'token_type': 'bearer', 'expires_in': 1200})
            return self.send(400, {'error': 'invalid_grant'})
        if not self.bearer(delinea):
            return self.send(401, {'message': 'Authentication failed'})
        delinea['calls'] += 1
        with lock:
            if url.path == '/api/v1/secrets' and method == 'GET':
                q = parse_qs(url.query)
                text, folder = q.get('filter.searchText', [''])[0], int(q.get('filter.folderId', ['-1'])[0])
                records = [{'id': i, 'name': s['name'], 'folderId': s['folderId']} for i, s in delinea['secrets'].items()
                           if text in s['name'] and s['folderId'] == folder and s['active']]
                return self.send(200, {'records': records, 'total': len(records)})
            if url.path == '/api/v1/secrets' and method == 'POST':
                d = json.loads(self.body())
                if d.get('folderId') != FOLDER_ID or d.get('secretTemplateId') != TEMPLATE_ID:
                    return self.send(400, {'message': 'Invalid folder or template'})
                items = {i['slug']: i['itemValue'] for i in d['items']}
                if 'password' not in items:
                    return self.send(400, {'message': 'Template field missing'})
                sid = delinea['next']; delinea['next'] += 1
                delinea['secrets'][sid] = {'name': d['name'], 'folderId': d['folderId'], 'items': items,
                                           'history': [], 'active': True}
                return self.send(200, {'id': sid, 'name': d['name']})
            m = re.fullmatch(r'/api/v1/secrets/(\d+)(?:/fields/([\w-]+))?', url.path)
            if not m or int(m.group(1)) not in delinea['secrets'] or not delinea['secrets'][int(m.group(1))]['active']:
                return self.send(404, {'message': 'Not found'})
            s = delinea['secrets'][int(m.group(1))]
            if m.group(2) and method == 'GET':
                return self.send(200, s['items'].get(m.group(2), ''))
            if m.group(2) and method == 'PUT':
                s['history'].append(s['items'].get(m.group(2)))
                s['items'][m.group(2)] = json.loads(self.body())['value']
                return self.send(200, {'id': int(m.group(1))})
            if not m.group(2) and method == 'DELETE':
                s['active'] = False
                return self.send(200, {'id': int(m.group(1)), 'objectType': 'Secret'})
        return self.send(405, {'message': 'Method not allowed'})

    def do_GET(self): self.handle_any('GET')
    def do_POST(self): self.handle_any('POST')
    def do_PUT(self): self.handle_any('PUT')
    def do_DELETE(self): self.handle_any('DELETE')


class Google(Base):
    def handle_any(self, method):
        url = urlparse(self.path)
        if url.path == '/_state':
            return self.send(200, {'secrets': {k: {'versions': len(v['versions']),
                                                   'enabled': sum(1 for x in v['versions'] if x['state'] == 'ENABLED'),
                                                   'annotations': v['annotations']}
                                               for k, v in gcp['secrets'].items()}, 'calls': gcp['calls']})
        if url.path == '/token' and method == 'POST':
            form = parse_qs(self.body().decode())
            try:
                claims = jwt.decode(form['assertion'][0], GCP_PUBLIC_KEY, algorithms=['RS256'],
                                    audience=f'http://{self.headers["Host"]}/token')
                assert form['grant_type'] == ['urn:ietf:params:oauth:grant-type:jwt-bearer']
                assert claims['scope'] == 'https://www.googleapis.com/auth/cloud-platform'
            except Exception as e:
                return self.send(400, {'error': 'invalid_grant', 'error_description': str(e)})
            token = secrets.token_hex(16)
            gcp['tokens'].add(token)
            return self.send(200, {'access_token': token, 'expires_in': 3599, 'token_type': 'Bearer'})
        if not self.bearer(gcp):
            return self.send(401, {'error': {'code': 401, 'status': 'UNAUTHENTICATED'}})
        gcp['calls'] += 1
        path = url.path[len('/v1/'):] if url.path.startswith('/v1/') else None
        with lock:
            m = re.fullmatch(r'projects/([\w-]+)/secrets', path or '')
            if m and method == 'POST':
                sid = parse_qs(url.query).get('secretId', [''])[0]
                if not re.fullmatch(r'[A-Za-z0-9_-]{1,255}', sid):
                    return self.send(400, {'error': {'code': 400, 'message': 'invalid secret id'}})
                name = f'projects/{m.group(1)}/secrets/{sid}'
                if name in gcp['secrets']:
                    return self.send(409, {'error': {'code': 409, 'status': 'ALREADY_EXISTS'}})
                d = json.loads(self.body())
                assert 'replication' in d
                gcp['secrets'][name] = {'versions': [], 'annotations': {}, 'labels': d.get('labels', {})}
                return self.send(200, {'name': name})
            m = re.fullmatch(r'(projects/[\w-]+/secrets/[\w-]+)(?::addVersion|/versions/(\w+)(:access|:destroy)?)?', path or '')
            if not m:
                return self.send(404, {'error': {'code': 404}})
            name = m.group(1)
            s = gcp['secrets'].get(name)
            if s is None:
                return self.send(404, {'error': {'code': 404, 'status': 'NOT_FOUND'}})
            if path.endswith(':addVersion') and method == 'POST':
                data = json.loads(self.body())['payload']['data']
                base64.b64decode(data)
                n = len(s['versions']) + 1
                s['versions'].append({'name': f'{name}/versions/{n}', 'data': data, 'state': 'ENABLED'})
                return self.send(200, {'name': f'{name}/versions/{n}', 'state': 'ENABLED'})
            if m.group(2):
                enabled = [v for v in s['versions'] if v['state'] == 'ENABLED']
                v = enabled[-1] if m.group(2) == 'latest' and enabled else \
                    next((x for x in s['versions'] if x['name'].endswith('/' + m.group(2))), None)
                if v is None or (m.group(3) != ':destroy' and v['state'] != 'ENABLED'):
                    return self.send(404, {'error': {'code': 404, 'status': 'NOT_FOUND'}})
                if m.group(3) == ':access':
                    return self.send(200, {'name': v['name'], 'payload': {'data': v['data']}})
                if m.group(3) == ':destroy' and method == 'POST':
                    v['state'], v['data'] = 'DESTROYED', ''
                    return self.send(200, {'name': v['name'], 'state': 'DESTROYED'})
                return self.send(200, {'name': v['name'], 'state': v['state']})
            if method == 'PATCH' and parse_qs(url.query).get('updateMask') == ['annotations']:
                s['annotations'] = json.loads(self.body()).get('annotations', {})
                return self.send(200, {'name': name})
            if method == 'DELETE':
                del gcp['secrets'][name]
                return self.send(200, {})
        return self.send(405, {'error': {'code': 405}})

    def do_GET(self): self.handle_any('GET')
    def do_POST(self): self.handle_any('POST')
    def do_PATCH(self): self.handle_any('PATCH')
    def do_DELETE(self): self.handle_any('DELETE')


for port, handler in ((8301, Delinea), (8302, Google)):
    threading.Thread(target=ThreadingHTTPServer(('0.0.0.0', port), handler).serve_forever, daemon=True).start()
print('mock vendors ready', flush=True)
while True:
    time.sleep(3600)
