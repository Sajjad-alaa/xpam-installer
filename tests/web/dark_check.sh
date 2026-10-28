#!/usr/bin/env bash
# The admin console in dark and light mode on a simulated XPAM server: screenshots of the main pages, and in dark
# mode an automatic check of every page for visible light patches (light backgrounds) and dark text on a dark
# background. Screenshots and the findings (findings.json) go to $OUT.
#   tests/web/dark_check.sh <web-image> [core-image] [gateway-image]      (ALL=1: every route of the console, dark only)
#   (the images are retagged inside the test server; nothing of the live system is used)
set -uo pipefail
WEB_IMAGE=${1:?web image, e.g. xpam/web:dark-check}
CORE_IMAGE=${2:-xpam/core:v5.1.20-dev}
GW_IMAGE=${3:-ghcr.io/sajjad-alaa/xpam/gateway:v5.1.19}
TAG=v5.1.99-check
OUT=${OUT:-/tmp/xpam-dark}
PW=${PW:-$(mktemp -d)}
PW_IMAGE=${PW_IMAGE:-mcr.microsoft.com/playwright:v1.63.0-noble}
NET=xdk; X=172.31.8.21
on() { local n=$1; shift; docker exec -i "$n" bash -lc "$*"; }
wait_for() { for _ in $(seq "${2:-60}"); do eval "$1" && return 0; sleep 5; done; return 1; }
say() { echo "== $(date +%T) $*"; }
cleanup() { docker rm -f xdkx xdkpw >/dev/null 2>&1; docker volume rm xdkx-docker >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; }
[[ "${KEEP:-}" == "1" ]] || trap cleanup EXIT
cleanup
mkdir -p "$OUT" "$PW"; chmod 777 "$OUT" "$PW"
MIN="XPAM_VAULT_MODE=none KOKO_ENABLED=0 CHEN_ENABLED=0 KAEL_ENABLED=0 BROWSER_ENABLED=0 WORKSPACE_ENABLED=0 WORKER_ENABLED=0 SERVER_SIZE=small XPAM_IMAGE_REGISTRY=local XPAM_VERSION=$TAG"
CORE_SHELL="docker exec -i xpam_core bash -c 'cd /opt/jumpserver/apps && python manage.py shell 2>/dev/null'"

say "test server"
docker network create --subnet 172.31.8.0/24 "$NET" >/dev/null
docker run -d --privileged --name xdkx --hostname xdkx --memory 2600m --memory-swap 2600m --cpus 2 --network $NET --ip $X \
  -v xdkx-docker:/var/lib/docker -v /opt/xpam-installer:/src:ro xpam-test/rocky-docker:9 >/dev/null
sleep 8
on xdkx 'systemctl start docker; git config --global --add safe.directory "*"'
on xdkx "cd /root && export $MIN XPAM_INSTALLER_REPO=/src AUTO_INSTALL=1 XPAM_SKIP_SELF_UPDATE=1; timeout 1200 bash /src/quick_start.sh > /root/install1.log 2>&1" || true
on xdkx "cp -a /src/scripts /src/xpamctl.sh /src/compose /opt/xpam-installer/"
docker save "$CORE_IMAGE" "$GW_IMAGE" "$WEB_IMAGE" postgres:16.15-bookworm redis:7.4.10-bookworm | docker exec -i xdkx docker load -q >/dev/null
on xdkx "docker tag $CORE_IMAGE xpam/core:$TAG; docker tag $GW_IMAGE xpam/gateway:$TAG; docker tag $WEB_IMAGE xpam/web:$TAG"
on xdkx "for kv in $MIN; do echo \$kv >> /opt/xpam/config/config.txt; done; cd /opt/xpam-installer && export $MIN AUTO_INSTALL=1 XPAM_SKIP_SELF_UPDATE=1; timeout 1800 bash ./xpamctl.sh install > /root/install2.log 2>&1"
wait_for "on xdkx 'docker ps --format \"{{.Names}} {{.Status}}\"' | grep -q '^xpam_web .*(healthy)'" 60 || { echo "XPAM did not start"; exit 1; }

say "some data, a session for the browser"
COOKIES=$(printf '%s\n' "import xpack.utils
xpack.utils.has_ticket_license = lambda: True
from django.test import Client; from django.conf import settings; from users.models import User
import json
User.objects.filter(username='admin').update(is_first_login=False)
c = Client(HTTP_HOST='localhost'); c.force_login(User.objects.get(username='admin'))
print('cookies', json.dumps({'session': [settings.SESSION_COOKIE_NAME, c.cookies[settings.SESSION_COOKIE_NAME].value]}))" \
  | on xdkx "$CORE_SHELL" | grep '^cookies ' | tail -1 | cut -d' ' -f2-)
# (the ticket and JIT pages need a licence with tickets: the trial has none — let the console have it)
on xdkx "docker exec xpam_core sh -c \"sed -i 's/^def has_ticket_license():/def has_ticket_license():\\n    return True\\ndef _orig_has_ticket_license():/' /opt/jumpserver/apps/xpack/utils.py\" && docker restart xpam_core >/dev/null"
wait_for "on xdkx 'docker ps --format \"{{.Names}} {{.Status}}\"' | grep -q '^xpam_core .*(healthy)'" 40

cat > "$PW/check.js" <<'JS'
const { chromium } = require('playwright');
const PAGES = [
  ['console-dashboard', '/web/#/console/dashboard'],
  ['pam-dashboard', '/web/#/pam/dashboard'],
  ['audit-dashboard', '/web/#/audit/dashboard'],
  ['users', '/web/#/console/users/users'],
  ['user-create', '/web/#/console/users/users/create'],
  ['assets', '/web/#/console/assets/assets'],
  ['perms', '/web/#/console/perms/asset-permissions'],
  ['custom-dashboards', '/web/#/console/custom-dashboards'],
  ['my-tickets', '/web/#/tickets/my-tickets'],
  ['ticket-request', '/web/#/tickets/tickets/request-host-perm/create'],
  ['jit-rules', '/web/#/pam/automations/jit-accounts'],
  ['jit-rule-form', '/web/#/pam/automations/jit-accounts/create'],
  ['reports', '/web/#/reports/dashboard'],
  ['audit-sessions', '/web/#/audit/sessions'],
  ['settings-basic', '/web/#/settings/basic'],
  ['settings-features', '/web/#/settings/features'],
  ['settings-ha', '/web/#/settings/high-availability'],
  ['settings-interface', '/web/#/settings/interface'],
  ['settings-log-shipment', '/web/#/settings/log-shipment'],
  ['settings-terminal', '/web/#/settings/terminal'],
  ['settings-license', '/web/#/settings/license'],
  ['settings-chat-ai', '/web/#/settings/chat-ai'],
];
// in dark mode: visible light backgrounds, and dark text on a dark background
const ANALYZE = () => {
  const parse = (c) => {
    const m = (c || '').match(/rgba?\(([^)]+)\)/);
    if (!m) return null;
    const p = m[1].split(/[\s,\/]+/).filter(Boolean).map(Number);
    if (p.length > 3 && p[3] < 0.5) return null;
    const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
    return 0.2126 * f(p[0]) + 0.7152 * f(p[1]) + 0.0722 * f(p[2]);
  };
  const visible = (el) => {
    const r = el.getBoundingClientRect(); const s = getComputedStyle(el);
    return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none' && +s.opacity > 0.1 &&
      r.bottom > 0 && r.top < innerHeight * 3;
  };
  const name = (el) => {
    const cls = [...el.classList].slice(0, 3).join('.');
    let comp = el.closest('[class*="-container"],[class*="page"],[class*="card"],[class*="dialog"],[class*="drawer"]');
    comp = comp && comp !== el ? ' in ' + [...comp.classList].slice(0, 2).join('.') : '';
    return `${el.tagName.toLowerCase()}${cls ? '.' + cls : ''}${comp}`;
  };
  const bgOf = (el) => {
    for (let e = el; e; e = e.parentElement) { const l = parse(getComputedStyle(e).backgroundColor); if (l !== null) return l; }
    return parse(getComputedStyle(document.body).backgroundColor) ?? 1;
  };
  const patches = [], darkText = [], lightText = [];
  for (const el of document.querySelectorAll('body *')) {
    if (['IMG', 'CANVAS', 'SVG', 'PATH', 'VIDEO', 'svg', 'path'].includes(el.tagName) || !visible(el)) continue;
    const s = getComputedStyle(el); const r = el.getBoundingClientRect();
    const bg = parse(s.backgroundColor);
    if (bg !== null && bg > 0.6 && r.width * r.height > 1500) patches.push([name(el), `${Math.round(r.width)}x${Math.round(r.height)}`, s.backgroundColor]);
    const hasText = [...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim().length > 1);
    if (hasText) {
      const fg = parse(s.color); const b = bgOf(el);
      if (fg !== null && fg < 0.12 && b < 0.12) darkText.push([name(el), el.textContent.trim().slice(0, 30), s.color]);
      if (fg !== null && fg > 0.45 && b > 0.45) lightText.push([name(el), el.textContent.trim().slice(0, 30), s.color]);
    }
  }
  const uniq = (a) => [...new Map(a.map((x) => [x[0], x])).values()];
  return { dark: document.documentElement.classList.contains('dark'), patches: uniq(patches).slice(0, 25), darkText: uniq(darkText).slice(0, 25), lightText: uniq(lightText).slice(0, 25) };
};
(async () => {
  const c = JSON.parse(process.env.COOKIES);
  const browser = await chromium.launch();
  const findings = (() => { try { return JSON.parse(require('fs').readFileSync('/out/findings.json')); } catch (e) { return {}; } })();
  for (const mode of [process.env.MODE]) {
    const ctx = await browser.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1440, height: 950 }, colorScheme: mode });
    await ctx.addInitScript((m) => { try { localStorage.setItem('lina-theme-mode', m); } catch (e) {} }, mode);
    await ctx.addCookies([{ name: c.session[0], value: c.session[1], url: 'https://127.0.0.1' }]);
    const page = await ctx.newPage();
    let pages = PAGES;
    if (process.env.ALL === '1' && mode === 'dark') {
      await page.goto('https://127.0.0.1/web/#/console/dashboard', { waitUntil: 'networkidle' });
      await page.waitForTimeout(2000);
      const paths = await page.evaluate(() => {
        const app = document.querySelector('#app').__vue_app__;
        const skip = /:|\*|login|logout|redirect|^\/(403|404|500)|^\/$|download|connect|luna|koko|redirect/i;
        return [...new Set(app.config.globalProperties.$router.getRoutes().map((r) => r.path))].filter((p) => !skip.test(p));
      });
      pages = paths.map((p) => [p.replace(/^\//, '').replace(/[\/]+/g, '_') || 'root', '/web/#' + p]);
      console.log('ROUTES ' + pages.length);
    }
    for (const [name, path] of pages) {
      try {
        await page.goto('https://127.0.0.1' + path, { waitUntil: 'networkidle', timeout: 30000 });
        await page.waitForTimeout(2500);
        const f = mode === 'dark' ? await page.evaluate(ANALYZE) : null;
        const found = f && (f.patches.length + f.darkText.length + f.lightText.length) > 0;
        if (process.env.ALL !== '1' || found) await page.screenshot({ path: `/out/${mode}-${name}.png` });
        if (f) findings[name] = f;
      } catch (e) { findings[name] = { error: String(e).slice(0, 200) }; }
    }
    // the Ctrl+K command palette and a dialog
    try {
      await page.goto('https://127.0.0.1/web/#/console/dashboard', { waitUntil: 'networkidle' });
      await page.waitForTimeout(1500);
      await page.keyboard.press('Control+K'); await page.waitForTimeout(1200);
      await page.screenshot({ path: `/out/${mode}-palette.png` });
      if (mode === 'dark') findings['palette'] = await page.evaluate(ANALYZE);
    } catch (e) { findings['palette'] = { error: String(e).slice(0, 200) }; }
    await ctx.close();
  }
  require('fs').writeFileSync('/out/findings.json', JSON.stringify(findings, null, 1));
  const total = Object.values(findings).reduce((n, f) => n + (f.patches ? f.patches.length + f.darkText.length + (f.lightText || []).length : 0), 0);
  console.log('FINDINGS ' + total);
  await browser.close();
})().catch((e) => { console.log('ERROR ' + e); process.exit(1); });
JS
# the theme mode is the administrator's choice (Settings -> Interface): set it, then look
set_mode() {
  printf '%s\n' "from django.test import Client; from users.models import User
c = Client(HTTP_HOST='localhost'); c.force_login(User.objects.get(username='admin'))
r = c.put('/api/v1/xpack/interface/setting/', {'theme_mode': '$1'}, content_type='application/json')
print('mode', r.status_code)" | on xdkx "$CORE_SHELL" | grep '^mode '
}
rm -f "$OUT/findings.json"
for MODE in dark light; do
  say "browser ($MODE)"
  set_mode "$MODE"
  docker run --rm --name xdkpw --network container:xdkx -v "$OUT:/out" -v "$PW:/pw" -e COOKIES="$COOKIES" -e MODE="$MODE" -e ALL="${ALL:-}" \
    -w /pw "$PW_IMAGE" bash -c 'test -d node_modules/playwright || npm i -s playwright@1.63.0 >/dev/null 2>&1; node check.js' 2>&1 \
    | grep -E '^(FINDINGS|ERROR|ROUTES)'
done
echo "screenshots and findings: $OUT"
