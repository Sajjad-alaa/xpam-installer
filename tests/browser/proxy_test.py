import http.server, socket, sys, threading, types, urllib.request
sys.path.insert(0, '/src')
import server
results = []
def check(name, ok, detail=''):
    results.append(bool(ok)); print(('PASS ' if ok else 'FAIL ') + name + (f'  [{detail}]' if detail != '' else ''), flush=True)
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'reached ' + self.headers.get('Host', '').encode())
    def log_message(self, *a): pass
own_ip = socket.gethostbyname(socket.gethostname())
srv = http.server.ThreadingHTTPServer((own_ip, 0), H); threading.Thread(target=srv.serve_forever, daemon=True).start()
lo = http.server.ThreadingHTTPServer(('127.0.0.1', 0), H); threading.Thread(target=lo.serve_forever, daemon=True).start()
def session(allowed):
    return types.SimpleNamespace(id='t', allowed=set(allowed), closed=threading.Event())
def via(proxy, url):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({'http': f'http://127.0.0.1:{proxy.port}'}))
    try:
        r = opener.open(url, timeout=5); return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, b''
    except Exception as e:
        return 0, repr(e).encode()
def connect(proxy, target, payload=b''):
    s = socket.create_connection(('127.0.0.1', proxy.port), timeout=5)
    s.sendall(f'CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n'.encode())
    head = s.recv(4096)
    body = b''
    if head.startswith(b'HTTP/1.1 200') and payload:
        s.sendall(payload); body = s.recv(4096)
    s.close(); return head.split(b'\r\n')[0], body
port = srv.server_address[1]
p1 = server.EgressProxy(session([]), 9601); p1.start()
st, body = via(p1, f'http://{own_ip}:{port}/')
check('an internal address not on the asset list is refused (plain HTTP)', st == 403, st)
p2 = server.EgressProxy(session([own_ip]), 9602); p2.start()
st, body = via(p2, f'http://{own_ip}:{port}/x')
check('an internal address on the asset list is reached (plain HTTP)', st == 200 and body.startswith(b'reached'), (st, body[:40]))
p3 = server.EgressProxy(session(['127.0.0.1', 'localhost']), 9603); p3.start()
st, _ = via(p3, f'http://127.0.0.1:{lo.server_address[1]}/')
check('loopback is refused even when listed (DevTools ports live there)', st == 403, st)
head, _ = connect(p3, 'localhost:9320')
check('CONNECT to a DevTools port on loopback is refused', head.startswith(b'HTTP/1.1 403'), head)
head, body = connect(p2, f'{own_ip}:{port}', f'GET /t HTTP/1.1\r\nHost: {own_ip}\r\nConnection: close\r\n\r\n'.encode())
check('CONNECT to a listed internal address tunnels', head.startswith(b'HTTP/1.1 200') and b'200' in body.split(b'\r\n')[0], (head, body[:30]))
head, _ = connect(p1, f'{own_ip}:{port}')
check('CONNECT to an unlisted internal address is refused', head.startswith(b'HTTP/1.1 403'), head)
real = socket.getaddrinfo
def fake(host, port, *a, **k):
    table = {'public.example': ['93.184.216.34'], 'rebind.example': ['93.184.216.34', '10.0.0.5'],
             'mapped.example': ['::ffff:192.168.1.1'], 'cgnat.example': ['100.64.1.1']}
    if host in table:
        return [(socket.AF_INET6 if ':' in ip else socket.AF_INET, socket.SOCK_STREAM, 6, '', (ip, port)) for ip in table[host]]
    return real(host, port, *a, **k)
server.socket.getaddrinfo = fake
check('a public site is allowed, to the address that was checked', p1.target_address('public.example', 443) == ('93.184.216.34', 443))
check('a name answering a public and an internal address is refused', p1.target_address('rebind.example', 443) is None)
check('an IPv4-mapped internal address is refused', p1.target_address('mapped.example', 80) is None)
check('carrier-grade NAT space counts as internal', p1.target_address('cgnat.example', 80) is None)
print(f'DONE {sum(results)}/{len(results)} passed')
