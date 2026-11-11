"""Isolated stack: the live ticket pages' WebSocket (/ws/tickets/events/) through the real web server — a ticket
change reaches only the users who may see the ticket (applicant, assignee, administrator of its organization, system
administrator), never anyone else; the message carries only the ticket id; a socket without a signed-in user or
from another site is refused; a user disabled while the page is open is cut off.
  run with tests/tickets/realtime_run.sh"""
import base64
import json
import os
import socket
import struct
import sys
import time

sys.path.insert(0, '/opt/core/apps'); os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'xpam.settings')
import django; django.setup()
from django.conf import settings
from django.db import transaction
from django.test import Client

settings.ALLOWED_HOSTS = list(settings.ALLOWED_HOSTS) + ['testserver']
from orgs.models import Organization
from orgs.utils import set_current_org
from rbac.builtin import BuiltinRole
from rbac.models import RoleBinding
from tickets.models import Comment, Ticket
from users.models import User

results = []


def check(name, ok, detail=''):
    results.append(bool(ok))
    print(('PASS ' if ok else 'FAIL ') + name + (f'  [{str(detail)[:240]}]' if detail != '' else ''), flush=True)


org = Organization.default(); set_current_org(org)
other_org = Organization.objects.filter(name='rt-other').first() or Organization.objects.create(name='rt-other')


def user(username, org_=org):
    u = User.objects.filter(username=username).first() or User.objects.create(
        username=username, name=username, email=f'{username}@example.invalid', is_first_login=False)
    org_.add_member(u)
    return u


admin = User.objects.get(username='admin')
applicant, assignee, bystander = user('rt.applicant'), user('rt.assignee'), user('rt.bystander')
org_admin, other_admin, leaver = user('rt.orgadmin'), user('rt.otheradmin', other_org), user('rt.leaver')
RoleBinding.objects.get_or_create(user=org_admin, role_id=BuiltinRole.org_admin.id, scope='org', org_id=org.id)
RoleBinding.objects.get_or_create(user=other_admin, role_id=BuiltinRole.org_admin.id, scope='org', org_id=other_org.id)


def session_cookie(u):
    c = Client()
    c.force_login(u)
    return f'{settings.SESSION_COOKIE_NAME}={c.cookies[settings.SESSION_COOKIE_NAME].value}'


class WS:
    def __init__(self, cookie=None, origin=None):
        self.sock = socket.create_connection(('127.0.0.1', 8080), timeout=5)
        key = base64.b64encode(os.urandom(16)).decode()
        lines = ['GET /ws/tickets/events/ HTTP/1.1', 'Host: 127.0.0.1:8080', 'Upgrade: websocket',
                 'Connection: Upgrade', f'Sec-WebSocket-Key: {key}', 'Sec-WebSocket-Version: 13']
        if cookie:
            lines.append(f'Cookie: {cookie}')
        if origin:
            lines.append(f'Origin: {origin}')
        self.sock.sendall(('\r\n'.join(lines) + '\r\n\r\n').encode())
        data = b''
        while b'\r\n\r\n' not in data:
            chunk = self.sock.recv(4096)
            if not chunk:
                break
            data += chunk
        head, _, self.buf = data.partition(b'\r\n\r\n')
        self.status = int(head.split(b' ')[1]) if head else 0
        self.closed = self.status != 101
        self.messages = []

    def read(self, seconds=2.0):
        end = time.time() + seconds
        self.sock.settimeout(0.2)
        while time.time() < end and not self.closed:
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                chunk = None
            if chunk == b'':
                self.closed = True
            elif chunk:
                self.buf += chunk
            while len(self.buf) >= 2:
                opcode, length, i = self.buf[0] & 0x0F, self.buf[1] & 0x7F, 2
                if length == 126:
                    length, i = struct.unpack('>H', self.buf[2:4])[0], 4
                elif length == 127:
                    length, i = struct.unpack('>Q', self.buf[2:10])[0], 10
                if len(self.buf) < i + length:
                    break
                payload, self.buf = self.buf[i:i + length], self.buf[i + length:]
                if opcode == 1:
                    self.messages.append(json.loads(payload))
                elif opcode == 8:
                    self.closed = True
        got, self.messages = self.messages, []
        return got


def ids(messages):
    return [m.get('id') for m in messages if m.get('type') == 'ticket_changed']


# --- refused connections
anon = WS()
check('a socket without a signed-in user is refused', anon.status != 101 or (anon.read(1.0) == [] and anon.closed),
      anon.status)
cross = WS(session_cookie(applicant), origin='https://evil.example')
check('a socket opened by another site\'s page is refused', cross.status != 101 or (cross.read(1.0) == [] and cross.closed),
      cross.status)

# --- one socket per user, all open before the ticket changes
names = ['admin', 'applicant', 'assignee', 'bystander', 'org_admin', 'other_admin', 'leaver']
users = dict(zip(names, [admin, applicant, assignee, bystander, org_admin, other_admin, leaver]))
sockets = {n: WS(session_cookie(u), origin='http://127.0.0.1:8080') for n, u in users.items()}
check('every signed-in user\'s socket opens (same-site origin)', all(s.status == 101 for s in sockets.values()),
      {n: s.status for n, s in sockets.items()})
time.sleep(1)

with transaction.atomic():  # (as in an API request: ATOMIC_REQUESTS)
    ticket = Ticket.objects.create(title='rt ticket', type='general', applicant=applicant, org_id=org.id)
    ticket.open_by_system([assignee])
got = {n: ids(s.read(3)) for n, s in sockets.items()}
tid = str(ticket.id)
should = {'admin', 'applicant', 'assignee', 'org_admin'}
check('the opened ticket is announced to applicant, assignee, organization and system administrators',
      all(tid in got[n] for n in should), got)
check('nobody else hears of it (other user, another organization\'s administrator)',
      all(tid not in got[n] for n in set(names) - should), got)
check('opening it (ticket, step and assignee in one transaction) is one announcement',
      all(got[n] == [tid] for n in should), got)

# a step and a comment
with transaction.atomic():
    ticket.approve(assignee)
got = {n: ids(s.read(3)) for n, s in sockets.items()}
check('an approval (ticket, step and assignees in one transaction) is announced once to each related user',
      all(got[n] == [tid] for n in should) and all(not got[n] for n in set(names) - should), got)

Comment.objects.create(ticket=ticket, user=assignee, user_display=str(assignee), body='looks fine')
got = {n: s.read(3) for n, s in sockets.items()}
check('a comment is announced to the related users only',
      all(tid in ids(got[n]) for n in should) and all(not got[n] for n in set(names) - should), got)
check('the message carries only the ticket id (no ticket content over the socket)',
      all(set(m) == {'type', 'id'} for n in should for m in got[n]), got['applicant'])

# a rolled back change is never announced, and does not stop later announcements of the same ticket
try:
    with transaction.atomic():
        Comment.objects.create(ticket=ticket, user=applicant, user_display=str(applicant), body='rolled back')
        raise RuntimeError('rollback')
except RuntimeError:
    pass
got = {n: ids(s.read(2)) for n, s in sockets.items()}
check('a rolled back change is not announced', not any(got.values()), got)
Comment.objects.create(ticket=ticket, user=applicant, user_display=str(applicant), body='after the rollback')
got = {n: ids(s.read(3)) for n, s in sockets.items()}
check('the next change of the same ticket is announced again', all(tid in got[n] for n in should), got)

# a user disabled while the page is open: no more events, the socket closes
leaver_ticket = Ticket.objects.create(title='rt leaver', type='general', applicant=leaver, org_id=org.id)
got = ids(sockets['leaver'].read(3))
check('the applicant hears of their own new ticket', str(leaver_ticket.id) in got, got)
User.objects.filter(id=leaver.id).update(is_active=False)
leaver_ticket.title = 'rt leaver 2'; leaver_ticket.save()
got = sockets['leaver'].read(3)
check('a user disabled while the page is open gets nothing more and is cut off',
      not ids(got) and sockets['leaver'].closed, (got, sockets['leaver'].closed))

for s in sockets.values():
    s.sock.close()
print(f'\n{sum(results)}/{len(results)} passed', flush=True)
sys.exit(0 if all(results) else 1)
