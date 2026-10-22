#!/usr/bin/env bash
# The console pages of 5.1.17 in a real browser: Account storage (Vault + data key), Vault connections, Vault storage
# rules, High availability, the account form's "read from an existing vault" — on a simulated XPAM server with the
# local Vault. Screenshots go to $OUT (default /tmp/xpam-console).
#   tests/vault/console_check.sh [tag]     (VAULT_FS_TAR: see xpam_test.sh; image mcr.microsoft.com/playwright)
set -uo pipefail
TAG=${1:-v5.1.17}
OUT=${OUT:-/tmp/xpam-console}
PW=${PW:-$(mktemp -d)}   # the browser's work folder (node_modules), kept apart from the screenshots
PW_IMAGE=${PW_IMAGE:-mcr.microsoft.com/playwright:v1.63.0-noble}
NET=xvc; X=172.31.5.21
PASS=0; FAIL=0
check() { if eval "$2"; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }
on() { local n=$1; shift; docker exec -i "$n" bash -lc "$*"; }
wait_for() { for _ in $(seq "${2:-60}"); do eval "$1" && return 0; sleep 5; done; return 1; }
say() { echo "== $(date +%T) $*"; }
cleanup() { docker rm -f xvcx xvcpw >/dev/null 2>&1; docker volume rm xvcx-docker >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; }
[[ "${KEEP:-}" == "1" ]] || trap cleanup EXIT
cleanup
mkdir -p "$OUT" "$PW"; chmod 777 "$OUT" "$PW"
MIN="XPAM_VAULT_MODE=none KOKO_ENABLED=0 CHEN_ENABLED=0 KAEL_ENABLED=0 BROWSER_ENABLED=0 WORKSPACE_ENABLED=0 WORKER_ENABLED=0 SERVER_SIZE=small XPAM_IMAGE_REGISTRY=local"
NODE_IMAGE=rockylinux/rockylinux:9-ubi-init
docker image inspect xpam-test/rocky-docker:9 >/dev/null 2>&1 && NODE_IMAGE=xpam-test/rocky-docker:9
CORE_SHELL="docker exec -i xpam_core bash -c 'cd /opt/jumpserver/apps && python manage.py shell 2>/dev/null'"

say "server"
docker network create --subnet 172.31.5.0/24 "$NET" >/dev/null
docker run -d --privileged --name xvcx --hostname xvcx --memory 2200m --memory-swap 2200m --cpus 2 --network $NET --ip $X \
  -v xvcx-docker:/var/lib/docker -v /opt/xpam-installer:/src:ro "$NODE_IMAGE" >/dev/null
sleep 8
on xvcx 'command -v docker >/dev/null && systemctl start docker; command -v git >/dev/null || for i in $(seq 20); do dnf -y -q install git tar procps-ng >/dev/null 2>&1 && rpm -q git >/dev/null && break; sleep 10; done; git config --global --add safe.directory "*"'

say "XPAM $TAG with the console"
on xvcx "cd /root && export $MIN XPAM_INSTALLER_REPO=/src AUTO_INSTALL=1 XPAM_SKIP_SELF_UPDATE=1; timeout 1200 bash /src/quick_start.sh > /root/install1.log 2>&1" || true
docker save "xpam/core:$TAG" "xpam/gateway:$TAG" "xpam/web:$TAG" postgres:16.15-bookworm redis:7.4.10-bookworm | docker exec -i xvcx docker load -q >/dev/null
on xvcx "for kv in $MIN; do echo \$kv >> /opt/xpam/config/config.txt; done; cd /opt/xpam-installer && export $MIN AUTO_INSTALL=1 XPAM_SKIP_SELF_UPDATE=1; timeout 1800 bash ./xpamctl.sh install > /root/install2.log 2>&1"
check 'XPAM with the console runs' "wait_for \"on xvcx 'docker ps --format \\\"{{.Names}} {{.Status}}\\\"' | grep -q '^xpam_web .*(healthy)'\" 60"

say "local Vault, a connection and a storage rule"
if [[ -s "${VAULT_FS_TAR:-}" ]]; then
  docker exec -i xvcx docker import --change 'ENTRYPOINT ["docker-entrypoint.sh"]' --change 'CMD ["server", "-dev"]' \
    --change 'USER vault' --change 'ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
    --change 'ENV NAME=vault' - hashicorp/vault:2.1.2 < "${VAULT_FS_TAR}" >/dev/null
fi
on xvcx "cd /opt/xpam-installer && timeout 1500 bash ./xpamctl.sh vault local > /root/local.log 2>&1"
check 'local Vault connected' "on xvcx 'grep -q \"secrets are in Vault\" /root/local.log'"
printf '%s' '{"VAULT_DELINEA_URL": "https://ss.example.com/SecretServer", "VAULT_DELINEA_USERNAME": "xpam-app", "VAULT_DELINEA_PASSWORD": "not-shown", "VAULT_DELINEA_FOLDER_ID": "7", "VAULT_DELINEA_TEMPLATE_ID": "6003"}' \
  | on xvcx "docker exec -i xpam_core bash -c 'cd /opt/jumpserver/apps && python manage.py xpam_vault_connection add --name delinea-prod --type delinea'" >/dev/null 2>&1
printf '%s\n' "from orgs.utils import set_current_org; from orgs.models import Organization; set_current_org(Organization.default())
from accounts.models import VaultConnection, VaultStorageRule
VaultStorageRule.objects.get_or_create(name='network devices', defaults={'priority': 10, 'username': 'net_*', 'connection': VaultConnection.objects.get(name='delinea-prod')})" \
  | on xvcx "$CORE_SHELL" >/dev/null

say "System settings create a rule in a chosen organization (the console runs in the System organization)"
API=$(printf '%s\n' "from django.test import Client; from users.models import User; from accounts.models import VaultConnection
from orgs.utils import tmp_to_root_org; from accounts.models import VaultStorageRule
c = Client(HTTP_HOST='localhost'); c.force_login(User.objects.get(username='admin'))
SYS = '00000000-0000-0000-0000-000000000004'; DEF = '00000000-0000-0000-0000-000000000002'
r = c.get('/api/v1/accounts/vault-rules/?limit=15', HTTP_X_JMS_ORG=SYS); print('api list', r.json()['count'], r.json()['results'][0]['org_name'])
r = c.post('/api/v1/accounts/vault-rules/', {'name': 'no org', 'priority': 20}, content_type='application/json', HTTP_X_JMS_ORG=SYS); print('api no-org', r.status_code)
r = c.post('/api/v1/accounts/vault-rules/', {'name': 'svc accounts', 'priority': 20, 'username': 'svc_*', 'org_id': DEF}, content_type='application/json', HTTP_X_JMS_ORG=SYS); print('api create', r.status_code)
with tmp_to_root_org(): rule = VaultStorageRule.objects.get(name='svc accounts')
print('api org', rule.org_id)
r = c.patch(f'/api/v1/accounts/vault-rules/{rule.id}/', {'priority': 30}, content_type='application/json', HTTP_X_JMS_ORG=SYS); print('api update', r.status_code)
r = c.delete(f'/api/v1/accounts/vault-rules/{rule.id}/', HTTP_X_JMS_ORG=SYS); print('api delete', r.status_code)" \
  | on xvcx "$CORE_SHELL" | grep '^api ')
echo "$API" | sed 's/^/  /'
check 'the rules list shows every organization (from System settings)' "grep -q '^api list 1 DEFAULT' <<<\"\$API\""
check 'a rule without an organization is refused' "grep -q '^api no-org 400' <<<\"\$API\""
check 'a rule is created, changed and deleted in the chosen organization' "grep -q '^api create 201' <<<\"\$API\" && grep -q '^api org 00000000-0000-0000-0000-000000000002' <<<\"\$API\" && grep -q '^api update 200' <<<\"\$API\" && grep -q '^api delete 204' <<<\"\$API\""

say "a signed-in browser"
COOKIES=$(printf '%s\n' "from django.test import Client; from django.conf import settings; from users.models import User
import json
User.objects.filter(username='admin').update(is_first_login=False)
c = Client(HTTP_HOST='localhost'); c.force_login(User.objects.get(username='admin'))
print('cookies', json.dumps({'session': [settings.SESSION_COOKIE_NAME, c.cookies[settings.SESSION_COOKIE_NAME].value], 'prefix': getattr(settings, 'SESSION_COOKIE_NAME_PREFIX', '')}))" \
  | on xvcx "$CORE_SHELL" | grep '^cookies ' | tail -1 | cut -d' ' -f2-)
echo "  session cookie: $( [[ -n "$COOKIES" ]] && echo obtained || echo MISSING)"
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
  const shot = async (name) => { await page.waitForTimeout(2500); await page.screenshot({ path: `/out/${name}.png`, fullPage: true }); out[name] = await page.innerText('body'); };
  await page.goto(`${base}/web/#/settings/features`, { waitUntil: 'networkidle' });
  for (const tab of ['Account storage', 'Vault connections', 'Vault storage rules']) {
    const el = page.getByText(tab, { exact: true }).first();
    if (await el.count()) { await el.click(); }
    await shot(tab.toLowerCase().replace(/ /g, '-'));
  }
  const create = page.locator('button:visible', { hasText: 'Create' }).first();
  out['rule-create-enabled'] = String(await create.isEnabled());
  if (await create.isEnabled()) { await create.click(); await shot('vault-storage-rule-create'); }
  await page.goto(`${base}/web/#/settings/high-availability`, { waitUntil: 'networkidle' });
  await shot('high-availability');
  console.log('BODY ' + JSON.stringify(out));
  await browser.close();
})().catch((e) => { console.log('ERROR ' + e); process.exit(1); });
JS
docker run --rm --name xvcpw --network container:xvcx -v "$OUT:/out" -v "$PW:/pw" -e COOKIES="$COOKIES" -w /pw "$PW_IMAGE" \
  bash -c 'test -d node_modules/playwright || npm i -s playwright@1.63.0 >/dev/null 2>&1; node check.js' > "$PW/result.txt" 2>&1
BODY=$(grep '^BODY ' "$PW/result.txt" | cut -d' ' -f2-)
grep '^ERROR' "$PW/result.txt"
txt() { python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get(sys.argv[2], ""))' "$BODY" "$1" 2>/dev/null; }
check 'Account storage shows the data key (Vault Transit) and the lock' "txt account-storage | grep -q 'HashiCorp Vault Transit' && txt account-storage | grep -q 'managed on the XPAM server'"
check 'Vault connections lists the connection (managed), never its password' "txt vault-connections | grep -q delinea-prod && ! txt vault-connections | grep -q not-shown"
check 'Vault storage rules lists the rule with its organization' "txt vault-storage-rules | grep -q 'network devices' && txt vault-storage-rules | grep -q DEFAULT"
check 'Vault storage rules: Create is enabled and the form asks for the organization' "[[ \$(txt rule-create-enabled) == true ]] && txt vault-storage-rule-create | grep -q Organization"
check 'High availability page is there' "txt high-availability | grep -qi 'high availability'"
ls "$OUT"/*.png 2>/dev/null | sed 's/^/  screenshot: /'
echo "RESULT: $PASS/$((PASS+FAIL)) passed"
[[ $FAIL -eq 0 ]]
