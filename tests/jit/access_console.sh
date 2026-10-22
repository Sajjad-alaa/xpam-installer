#!/usr/bin/env bash
# The 5.1.18 access screens in a real browser on a simulated XPAM server: the ticket list's Access column, the
# ticket's Access tab (state, protocols, actions, end/extend/revoke), the rule form's allowed protocols and
# actions, and the Workspace request panel with its protocol and action choices. Screenshots go to $OUT.
#   tests/jit/access_console.sh [tag]      (PW: the browser's work folder with playwright installed)
set -uo pipefail
TAG=${1:-v5.1.18-dev}
OUT=${OUT:-/tmp/xpam-access}
PW=${PW:-$(mktemp -d)}
PW_IMAGE=${PW_IMAGE:-mcr.microsoft.com/playwright:v1.63.0-noble}
NET=xac; X=172.31.6.21
PASS=0; FAIL=0
check() { if eval "$2"; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }
on() { local n=$1; shift; docker exec -i "$n" bash -lc "$*"; }
wait_for() { for _ in $(seq "${2:-60}"); do eval "$1" && return 0; sleep 5; done; return 1; }
say() { echo "== $(date +%T) $*"; }
cleanup() { docker rm -f xacx xacpw >/dev/null 2>&1; docker volume rm xacx-docker >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; }
[[ "${KEEP:-}" == "1" ]] || trap cleanup EXIT
cleanup
mkdir -p "$OUT" "$PW"; chmod 777 "$OUT" "$PW"
MIN="XPAM_VAULT_MODE=none KOKO_ENABLED=0 CHEN_ENABLED=0 KAEL_ENABLED=0 BROWSER_ENABLED=0 WORKER_ENABLED=0 SERVER_SIZE=small XPAM_IMAGE_REGISTRY=local XPAM_VERSION=$TAG"
NODE_IMAGE=xpam-test/rocky-docker:9
CORE_SHELL="docker exec -i xpam_core bash -c 'cd /opt/jumpserver/apps && python manage.py shell 2>/dev/null'"

say "server with XPAM $TAG"
docker network create --subnet 172.31.6.0/24 "$NET" >/dev/null
docker run -d --privileged --name xacx --hostname xacx --memory 2200m --memory-swap 2200m --cpus 2 --network $NET --ip $X \
  -v xacx-docker:/var/lib/docker -v /opt/xpam-installer:/src:ro "$NODE_IMAGE" >/dev/null
sleep 8
on xacx 'systemctl start docker; git config --global --add safe.directory "*"'
on xacx "cd /root && export $MIN XPAM_INSTALLER_REPO=/src AUTO_INSTALL=1 XPAM_SKIP_SELF_UPDATE=1; timeout 1200 bash /src/quick_start.sh > /root/install1.log 2>&1" || true
docker save "xpam/core:$TAG" "xpam/gateway:$TAG" "xpam/web:$TAG" "xpam/workspace:$TAG" postgres:16.15-bookworm redis:7.4.10-bookworm | docker exec -i xacx docker load -q >/dev/null
on xacx "for kv in $MIN; do echo \$kv >> /opt/xpam/config/config.txt; done; cd /opt/xpam-installer && export $MIN AUTO_INSTALL=1 XPAM_SKIP_SELF_UPDATE=1; timeout 1800 bash ./xpamctl.sh install > /root/install2.log 2>&1"
check 'XPAM runs (console and workspace)' "wait_for \"on xacx 'docker ps --format \\\"{{.Names}} {{.Status}}\\\"' | grep -q '^xpam_web .*(healthy)'\" 60"

say "a rule (SSH only, connect + download), an approved request with an active access"
printf '%s\n' "import xpack.utils
xpack.utils.has_ticket_license = lambda: True
from orgs.models import Organization; from orgs.utils import set_current_org; org = Organization.default(); set_current_org(org)
from users.models import User; admin = User.objects.get(username='admin'); User.objects.filter(id=admin.id).update(is_first_login=False)
from assets.models import Host, Platform, Node
host = Host.objects.filter(name='web-01').first() or Host.objects.create(name='web-01', address='10.0.0.5', platform=Platform.objects.get(name='Linux'), org_id=org.id)
host.nodes.set([Node.org_root()]); host.protocols.all().delete()
host.protocols.create(name='ssh', port=22); host.protocols.create(name='sftp', port=22)
from accounts.models import JITPolicy
p = JITPolicy.objects.create(name='Developers: SSH only', org_id=org.id, scope='all', priority=5, self_service=True, jit_only=True, require_reason=False, auto_approve=True, auto_approve_max_hours=4, max_hours=4, protocols=['ssh'], actions=1|4)
p.users = {'type': 'ids', 'ids': [str(admin.id)]}; p.assets = {'type': 'ids', 'ids': [str(host.id)]}; p.save()
from accounts.jit import selfservice
class R: user = admin
t = selfservice.submit(R(), [host.id], 2, reason='deploy hotfix 2.4.1')
print('ticket', t.id, t.state)
print('rule', p.id)" | on xacx "$CORE_SHELL" | grep -E '^(ticket|rule) ' > "$PW/ids.txt"
cat "$PW/ids.txt"
TICKET=$(awk '/^ticket/ {print $2}' "$PW/ids.txt"); RULE=$(awk '/^rule/ {print $2}' "$PW/ids.txt")
check 'the request was approved by the rule' "grep -q 'approved' $PW/ids.txt"

say "browser"
COOKIES=$(printf '%s\n' "from django.test import Client; from django.conf import settings; from users.models import User
import json
c = Client(HTTP_HOST='localhost'); c.force_login(User.objects.get(username='admin'))
print('cookies', json.dumps({'session': [settings.SESSION_COOKIE_NAME, c.cookies[settings.SESSION_COOKIE_NAME].value]}))" \
  | on xacx "$CORE_SHELL" | grep '^cookies ' | tail -1 | cut -d' ' -f2-)
# (the tickets feature needs a licence with tickets: the test server's trial has none — let the console have it)
on xacx "docker exec xpam_core sh -c \"sed -i 's/^def has_ticket_license():/def has_ticket_license():\\n    return True\\ndef _orig_has_ticket_license():/' /opt/jumpserver/apps/xpack/utils.py\" && docker restart xpam_core >/dev/null"
wait_for "on xacx 'docker ps --format \"{{.Names}} {{.Status}}\"' | grep -q '^xpam_core .*(healthy)'" 40
cat > "$PW/check.js" <<'JS'
const { chromium } = require('playwright');
(async () => {
  const c = JSON.parse(process.env.COOKIES);
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1440, height: 1000 } });
  const base = 'https://127.0.0.1';
  await ctx.addCookies([{ name: c.session[0], value: c.session[1], url: base }]);
  const page = await ctx.newPage();
  const out = {};
  const shot = async (name) => { await page.waitForTimeout(3000); await page.screenshot({ path: `/out/${name}.png`, fullPage: true }); out[name] = await page.innerText('body'); };
  await page.goto(`${base}/web/#/tickets/my-tickets`, { waitUntil: 'networkidle' });
  await shot('ticket-list');
  await page.goto(`${base}/web/#/tickets/tickets/request-host-perm/${process.env.TICKET}`, { waitUntil: 'networkidle' });
  await page.waitForTimeout(2000);
  const tab = page.getByText('Access', { exact: true }).first();
  if (await tab.count()) { await tab.click(); }
  await shot('ticket-access');
  await page.goto(`${base}/web/#/pam/automations/jit-accounts/${process.env.RULE}/update`, { waitUntil: 'networkidle' });
  await shot('rule-form');
  await page.goto(`${base}/workspace/access`, { waitUntil: 'networkidle' });
  await page.waitForTimeout(3000);
  const card = page.getByText('web-01').first();
  if (await card.count()) { await card.click(); }
  await shot('workspace-access');
  console.log('BODY ' + JSON.stringify(out));
  await browser.close();
})().catch((e) => { console.log('ERROR ' + e); process.exit(1); });
JS
docker run --rm --name xacpw --network container:xacx -v "$OUT:/out" -v "$PW:/pw" -e COOKIES="$COOKIES" -e TICKET="$TICKET" -e RULE="$RULE" -w /pw "$PW_IMAGE" \
  bash -c 'test -d node_modules/playwright || npm i -s playwright@1.63.0 >/dev/null 2>&1; node check.js' > "$PW/result.txt" 2>&1
BODY=$(grep '^BODY ' "$PW/result.txt" | cut -d' ' -f2-)
grep '^ERROR' "$PW/result.txt"
txt() { python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2], ""))' "$BODY" "$1" 2>/dev/null; }
check 'the ticket list shows the Access column (Active)' "txt ticket-list | grep -q 'Active'"
check 'the ticket Access tab: active, protocols, actions, revoke' "txt ticket-access | grep -q 'Revoke now' && txt ticket-access | grep -qi 'ssh' && txt ticket-access | grep -q 'left'"
check 'the rule form has allowed protocols and actions' "txt rule-form | grep -q 'Allowed protocols' && txt rule-form | grep -q 'Allowed actions'"
check 'the Workspace page shows the access with its choices' "txt workspace-access | grep -q 'web-01'"
ls "$OUT"/*.png 2>/dev/null | sed 's/^/  screenshot: /'
echo "RESULT: $PASS/$((PASS+FAIL)) passed"
[[ $FAIL -eq 0 ]]
