"""The service's own session (Xvfb + Chromium + guard + proxy): the asset page loads; requests from the page to
loopback (where the DevTools ports are) and to an internal address that is not on the asset's list never arrive."""
import http.server, os, socket, sys, threading, time
sys.path.insert(0, '/src')
import server
hits = {'page': 0, 'lo': [], 'other': []}
own_ip = socket.gethostbyname(socket.gethostname())
OTHER = sys.argv[1] if len(sys.argv) > 1 else ''
class Lo(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        hits['lo'].append(self.path); self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
lo = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Lo); threading.Thread(target=lo.serve_forever, daemon=True).start()
LO = lo.server_address[1]
class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        hits['page'] += 1
        other = f'fetch("http://{OTHER}/x").catch(()=>0);' if OTHER else ''
        body = (f'<html><body><h1>page ok</h1><img src="http://127.0.0.1:{LO}/img">'
                f'<script>fetch("http://127.0.0.1:{LO}/fetch").catch(()=>0);'
                f'try{{new WebSocket("ws://127.0.0.1:{LO}/ws")}}catch(e){{}};'
                f'fetch("http://localhost:{LO}/name").catch(()=>0);{other}</script></body></html>').encode()
        self.send_response(200); self.send_header('Content-Type', 'text/html'); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
p = http.server.ThreadingHTTPServer((own_ip, 0), Page); threading.Thread(target=p.serve_forever, daemon=True).start()
config = server.clean_config({'url': f'http://{own_ip}:{p.server_address[1]}/', 'width': 1280, 'height': 800,
                              'autofill': 'no'})
session = server.create(config)
time.sleep(12)
print('page requests:', hits['page'], '| loopback requests:', hits['lo'], '| proxy refusals:', session.proxy.blocked, flush=True)
renderers, own_ns = [], os.readlink('/proc/self/ns/user')
for pid in os.listdir('/proc'):
    try:
        cmd = open(f'/proc/{pid}/cmdline', 'rb').read()
        if b'--type=renderer' in cmd:
            renderers.append(os.readlink(f'/proc/{pid}/ns/user') != own_ns)
    except OSError:
        pass
print('renderers:', len(renderers), '| in their own user namespace (sandboxed):', renderers.count(True), flush=True)
server.release(session.id)
