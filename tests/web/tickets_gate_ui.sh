#!/usr/bin/env bash
# Just-in-time access appears only with Tickets enabled and licensed — in the browser, on a simulated XPAM server:
# the console's JIT and ticket menus, the JIT pages and API, the JIT section of an asset permission, the Ctrl+K
# quick actions, and the Workspace's Access page; in three states: Tickets on (licensed), Tickets off, no ticket
# licence. Screenshots go to $OUT.
#   tests/web/tickets_gate_ui.sh [tag]      (images xpam/core, gateway, web, workspace:<tag> local)
set -uo pipefail
TAG=${1:-v5.1.21-dev}
OUT=${OUT:-/tmp/xpam-tickets-gate}
PW=${PW:-$(mktemp -d)}
PW_IMAGE=${PW_IMAGE:-mcr.microsoft.com/playwright:v1.63.0-noble}
NET=xtg; X=172.31.9.21
PASS=0; FAIL=0
check() { if eval "$2"; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }
on() { local n=$1; shift; docker exec -i "$n" bash -lc "$*"; }
wait_for() { for _ in $(seq "${2:-60}"); do eval "$1" && return 0; sleep 5; done; return 1; }
say() { echo "== $(date +%T) $*"; }
cleanup() { docker rm -f xtgx xtgpw >/dev/null 2>&1; docker volume rm xtgx-docker >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; }
[[ "${KEEP:-}" == "1" ]] || trap cleanup EXIT
cleanup
mkdir -p "$OUT" "$PW"; chmod 777 "$OUT" "$PW"
MIN="XPAM_VAULT_MODE=none KOKO_ENABLED=0 CHEN_ENABLED=0 KAEL_ENABLED=0 BROWSER_ENABLED=0 WORKER_ENABLED=0 SERVER_SIZE=small XPAM_IMAGE_REGISTRY=local XPAM_VERSION=$TAG"
CORE_SHELL="docker exec -i xpam_core bash -c 'cd /opt/jumpserver/apps && python manage.py shell 2>/dev/null'"

say "test server"
docker network create --subnet 172.31.9.0/24 "$NET" >/dev/null
docker run -d --privileged --name xtgx --hostname xtgx --memory 2600m --memory-swap 2600m --cpus 2 --network $NET --ip $X \
  -v xtgx-docker:/var/lib/docker -v /opt/xpam-installer:/src:ro xpam-test/rocky-docker:9 >/dev/null
sleep 8
on xtgx 'systemctl start docker; git config --global --add safe.directory "*"'
on xtgx "cd /root && export $MIN XPAM_INSTALLER_REPO=/src AUTO_INSTALL=1 XPAM_SKIP_SELF_UPDATE=1; timeout 1200 bash /src/quick_start.sh > /root/install1.log 2>&1" || true
docker save "xpam/core:$TAG" "xpam/gateway:$TAG" "xpam/web:$TAG" "xpam/workspace:$TAG" postgres:16.15-bookworm redis:7.4.10-bookworm \
  | docker exec -i xtgx docker load -q >/dev/null
on xtgx "for kv in $MIN; do echo \$kv >> /opt/xpam/config/config.txt; done; cd /opt/xpam-installer && export $MIN AUTO_INSTALL=1 XPAM_SKIP_SELF_UPDATE=1; timeout 1800 bash ./xpamctl.sh install > /root/install2.log 2>&1"
wait_for "on xtgx 'docker ps --format \"{{.Names}} {{.Status}}\"' | grep -q '^xpam_workspace .*(healthy)'" 60 || { echo "XPAM did not start"; exit 1; }

COOKIES=$(printf '%s\n' "from django.test import Client; from django.conf import settings; from users.models import User
import json
User.objects.filter(username='admin').update(is_first_login=False)
c = Client(HTTP_HOST='localhost'); c.force_login(User.objects.get(username='admin'))
print('cookies', json.dumps({'session': [settings.SESSION_COOKIE_NAME, c.cookies[settings.SESSION_COOKIE_NAME].value]}))" \
  | on xtgx "$CORE_SHELL" | grep '^cookies ' | tail -1 | cut -d' ' -f2-)

# the ticket licence: the trial has none — "licensed" patches the check in the running core, "unlicensed" restores it
licence() {
  if [[ "$1" == on ]]; then
    on xtgx "docker exec xpam_core sh -c \"grep -q _orig_has_ticket_license /opt/jumpserver/apps/xpack/utils.py || sed -i 's/^def has_ticket_license():/def has_ticket_license():\\n    return True\\ndef _orig_has_ticket_license():/' /opt/jumpserver/apps/xpack/utils.py\""
  else
    on xtgx "docker exec xpam_core sh -c \"sed -i '/^def has_ticket_license():/{n;/^    return True\$/d}; s/^def _orig_has_ticket_license():/def has_ticket_license():/' /opt/jumpserver/apps/xpack/utils.py; grep -n -A1 '^def has_ticket_license' /opt/jumpserver/apps/xpack/utils.py | head -2\""
  fi
  on xtgx "docker restart xpam_core >/dev/null"
  wait_for "on xtgx 'docker ps --format \"{{.Names}} {{.Status}}\"' | grep -q '^xpam_core .*(healthy)'" 40
}
tickets_setting() {
  printf '%s\n' "from django.test import Client; from users.models import User
c = Client(HTTP_HOST='localhost'); c.force_login(User.objects.get(username='admin'))
print('tickets', c.patch('/api/v1/settings/setting/?category=ticket', {'TICKETS_ENABLED': $1}, content_type='application/json').status_code)" \
    | on xtgx "$CORE_SHELL" | grep '^tickets '
}

cat > "$PW/check.js" <<'JS'
const { chromium } = require('playwright');
(async () => {
  const c = JSON.parse(process.env.COOKIES); const state = process.env.STATE;
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1440, height: 950 } });
  await ctx.addCookies([{ name: c.session[0], value: c.session[1], url: 'https://127.0.0.1' }]);
  const page = await ctx.newPage(); const base = 'https://127.0.0.1'; const out = {};
  const menu = async () => page.evaluate(() => [...document.querySelectorAll('.el-menu-item, .el-sub-menu__title')]
    .map((e) => e.innerText.trim()).filter(Boolean));
  await page.goto(`${base}/web/#/pam/dashboard`, { waitUntil: 'networkidle' }); await page.waitForTimeout(2500);
  out.pamMenu = await menu();
  await page.screenshot({ path: `/out/${state}-pam-menu.png` });
  await page.goto(`${base}/web/#/console/dashboard`, { waitUntil: 'networkidle' }); await page.waitForTimeout(2000);
  out.consoleMenu = await menu();
  // the top navigation's view switcher (Console / PAM / Audit / Tickets ...)
  out.topText = await page.evaluate(() => document.body.innerText.slice(0, 4000));
  out.api = await page.evaluate(async () => {
    const r = await fetch('/api/v1/accounts/jit-policies/?limit=1', { credentials: 'include' });
    const s = await fetch('/api/v1/settings/public/', { credentials: 'include' }).then((x) => x.json());
    return { jitPolicies: r.status, TICKETS_ENABLED: s.TICKETS_ENABLED, HAS_TICKET_LICENSE: s.HAS_TICKET_LICENSE };
  });
  await page.keyboard.press('Control+K'); await page.waitForTimeout(1200);
  out.palette = await page.evaluate(() => [...document.querySelectorAll('.list .item')].map((e) => e.innerText.trim().split('\n')[0]));
  await page.keyboard.press('Escape');
  await page.goto(`${base}/web/#/console/perms/asset-permissions/create`, { waitUntil: 'networkidle' }); await page.waitForTimeout(2500);
  out.permForm = await page.evaluate(() => document.body.innerText);
  await page.screenshot({ path: `/out/${state}-perm-form.png`, fullPage: true });
  await page.goto(`${base}/web/#/pam/automations/jit-accounts`, { waitUntil: 'networkidle' }); await page.waitForTimeout(2500);
  out.jitPageUrl = page.url(); out.jitPage = await page.evaluate(() => document.body.innerText.slice(0, 1500));
  await page.screenshot({ path: `/out/${state}-jit-page.png` });
  await page.goto(`${base}/workspace/`, { waitUntil: 'networkidle' }); await page.waitForTimeout(4000);
  out.workspaceModes = await page.evaluate(() => [...document.querySelectorAll('button, a, [role="button"]')]
    .map((e) => (e.getAttribute('aria-label') || e.getAttribute('title') || e.innerText || '').trim()).filter(Boolean));
  await page.screenshot({ path: `/out/${state}-workspace.png` });
  console.log('OUT ' + JSON.stringify(out));
  await browser.close();
})().catch((e) => { console.log('ERROR ' + e); process.exit(1); });
JS
look() {
  docker run --rm --name xtgpw --network container:xtgx -v "$OUT:/out" -v "$PW:/pw" -e COOKIES="$COOKIES" -e STATE="$1" -w /pw "$PW_IMAGE" \
    bash -c 'test -d node_modules/playwright || npm i -s playwright@1.63.0 >/dev/null 2>&1; node check.js' 2>&1 | grep -E '^(OUT|ERROR)' > "$PW/$1.txt"
  grep '^ERROR' "$PW/$1.txt"
}
get() { python3 -c 'import json,sys; d=json.loads(open(sys.argv[1]).read()[4:]); v=d
for k in sys.argv[2].split("."): v=v[k]
print(json.dumps(v))' "$PW/$1.txt" "$2" 2>/dev/null; }
has() { get "$1" "$2" | grep -qi -- "$3"; }

say "1. Tickets enabled and licensed"
licence on; tickets_setting True; look on
check 'on: settings say Tickets enabled and licensed' "has on api.TICKETS_ENABLED true && has on api.HAS_TICKET_LICENSE true"
check 'on: the PAM menu shows Just-in-time accounts' "has on pamMenu 'Just-in-time'"
check 'on: the JIT API answers' "has on api.jitPolicies 200"
check 'on: the asset permission form has the JIT section' "has on permForm 'Just-in-time'"
check 'on: Ctrl+K offers JIT Policies and My Tickets' "has on palette 'JIT Policies' && has on palette 'My Tickets'"
check 'on: the Workspace shows Access' "has on workspaceModes 'Access'"

say "2. Tickets switched off (licensed)"
tickets_setting False; look off
check 'off: settings say Tickets disabled' "has off api.TICKETS_ENABLED false"
check 'off: no Just-in-time accounts in the PAM menu' "! has off pamMenu 'Just-in-time'"
check 'off: the JIT API refuses (403)' "has off api.jitPolicies 403"
check 'off: no JIT section in the asset permission form' "! has off permForm 'Just-in-time'"
check 'off: Ctrl+K offers no ticket or JIT actions' "! has off palette 'JIT Policies' && ! has off palette 'My Tickets'"
check 'off: the Workspace shows no Access' "! has off workspaceModes '\"Access'"
check 'off: the JIT page itself does not show the rules' "! has off jitPage 'Create just-in-time'"

say "3. Tickets on, no ticket licence"
tickets_setting True; licence off; look nolic
check 'no licence: settings say unlicensed' "has nolic api.HAS_TICKET_LICENSE false"
check 'no licence: no Just-in-time accounts in the PAM menu' "! has nolic pamMenu 'Just-in-time'"
check 'no licence: the JIT API refuses (403)' "has nolic api.jitPolicies 403"
check 'no licence: no JIT section in the asset permission form' "! has nolic permForm 'Just-in-time'"
check 'no licence: the Workspace shows no Access' "! has nolic workspaceModes '\"Access'"

ls "$OUT"/*.png 2>/dev/null | sed 's/^/  screenshot: /'
echo "RESULT: $PASS/$((PASS+FAIL)) passed"
[[ $FAIL -eq 0 ]]
