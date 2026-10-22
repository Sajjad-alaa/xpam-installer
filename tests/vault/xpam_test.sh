#!/usr/bin/env bash
# XPAM with its secrets in HashiCorp Vault: the real `xpamctl vault connect` on a simulated XPAM server
# (privileged Rocky Linux container, reduced install: core, gateway, SSH/RDP service) and a Vault server set
# up by the kit (single node here).
#   tests/vault/xpam_test.sh [tag]      (images xpam/core, xpam/gateway, xpam/secureconnection:<tag> local)
# Checks: connect; no secret in config.txt nor in any container's settings (docker inspect / Docker's files);
# XPAM and the SSH/RDP service run; account secrets in Vault only and still usable; console lock; status;
# reboot; Vault unreachable at boot (XPAM waits, no new secret); the installer keeps the Vault values;
# SECRET_KEY rotation; disconnect.
set -uo pipefail
TAG=${1:-v5.1.17}
NET=xvt; V=172.31.6.11; X=172.31.6.21
PASS=0; FAIL=0
check() { if eval "$2"; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }
on() { local n=$1; shift; docker exec -i "$n" bash -lc "$*"; }  # (-i: scripts can be piped in)
wait_for() { for _ in $(seq "${2:-60}"); do eval "$1" && return 0; sleep 5; done; return 1; }
say() { echo "== $(date +%T) $*"; }
cleanup() {
  docker rm -f xvtv xvtx >/dev/null 2>&1
  docker volume rm xvtv-docker xvtx-docker >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
}
[[ "${KEEP:-}" == "1" ]] || trap cleanup EXIT
cleanup
export XPAM_VAULT_PASSPHRASE="Kit-$(head -c 32 /dev/urandom | tr -dc A-Za-z0-9 | head -c 20)"
export XPAM_VAULT_BUNDLE_PASSPHRASE="Bundle-$(head -c 32 /dev/urandom | tr -dc A-Za-z0-9 | head -c 20)"
export XPAM_VAULT_RECOVERY_PASSPHRASE="Recovery-$(head -c 32 /dev/urandom | tr -dc A-Za-z0-9 | head -c 20)"
PW="XPAM_VAULT_PASSPHRASE=$XPAM_VAULT_PASSPHRASE XPAM_VAULT_BUNDLE_PASSPHRASE=$XPAM_VAULT_BUNDLE_PASSPHRASE XPAM_VAULT_RECOVERY_PASSPHRASE=$XPAM_VAULT_RECOVERY_PASSPHRASE XPAM_VAULT_ALLOW_SWAP=1"
MIN="XPAM_VAULT_MODE=none CHEN_ENABLED=0 KAEL_ENABLED=0 BROWSER_ENABLED=0 WORKSPACE_ENABLED=0 WEB_ENABLED=0 WORKER_ENABLED=0 SERVER_SIZE=small XPAM_IMAGE_REGISTRY=local"
CORE_SHELL="docker exec -i xpam_core bash -c 'cd /opt/jumpserver/apps && python manage.py shell 2>/dev/null'"

# the Vault image: from the host (VAULT_FS_TAR, `docker export` of a hashicorp/vault:2.1.2 container) or pulled
load_vault() {
  if [[ -s "${VAULT_FS_TAR:-}" ]]; then
    docker exec -i "$1" docker import --change 'ENTRYPOINT ["docker-entrypoint.sh"]' --change 'CMD ["server", "-dev"]' \
      --change 'USER vault' --change 'ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
      --change 'ENV NAME=vault' - hashicorp/vault:2.1.2 < "${VAULT_FS_TAR}" >/dev/null
  else
    on "$1" "for i in 1 2 3 4 5; do timeout 300 docker pull -q hashicorp/vault:2.1.2 >/dev/null 2>&1 && break; sleep 5; done"
  fi
}

say "servers"
docker network create --subnet 172.31.6.0/24 "$NET" >/dev/null
NODE_IMAGE=rockylinux/rockylinux:9-ubi-init
docker image inspect xpam-test/rocky-docker:9 >/dev/null 2>&1 && NODE_IMAGE=xpam-test/rocky-docker:9
docker run -d --privileged --name xvtv --hostname xvtv --memory 450m --memory-swap 450m --cpus 1 --network $NET --ip $V \
  -v xvtv-docker:/var/lib/docker -v /opt/xpam-installer:/src:ro "$NODE_IMAGE" >/dev/null
docker run -d --privileged --name xvtx --hostname xvtx --memory 1800m --memory-swap 1800m --cpus 2 --network $NET --ip $X \
  -v xvtx-docker:/var/lib/docker -v /opt/xpam-installer:/src:ro rockylinux/rockylinux:9-ubi-init >/dev/null
sleep 8
on xvtv 'command -v docker >/dev/null && systemctl start docker && exit 0; for i in $(seq 20); do dnf -y -q install dnf-plugins-core iptables-nft iproute python3 openssl tar procps-ng >/dev/null 2>&1 && break; sleep 10; done
  dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo >/dev/null 2>&1
  for i in $(seq 10); do dnf -y -q install docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null 2>&1 && break; sleep 10; done
  mkdir -p /etc/docker; echo "{\"features\":{\"containerd-snapshotter\":false}}" > /etc/docker/daemon.json
  systemctl enable --now docker >/dev/null 2>&1
  for i in 1 2 3 4 5; do timeout 300 docker pull -q hashicorp/vault:2.1.2 >/dev/null 2>&1 && break; sleep 5; done' &
on xvtx 'for i in $(seq 20); do dnf -y -q install git tar iptables-nft procps-ng iproute python3 openssl >/dev/null 2>&1 && rpm -q git >/dev/null && break; sleep 10; done; git config --global --add safe.directory "*"' &
wait

load_vault xvtv

say "XPAM (reduced: core, gateway, SSH/RDP service)"
on xvtx "cd /root && export $MIN XPAM_INSTALLER_REPO=/src AUTO_INSTALL=1 XPAM_SKIP_SELF_UPDATE=1; timeout 1200 bash /src/quick_start.sh > /root/install1.log 2>&1" || true
docker save "xpam/core:$TAG" "xpam/gateway:$TAG" "xpam/secureconnection:$TAG" postgres:16.15-bookworm redis:7.4.10-bookworm \
  | docker exec -i xvtx docker load -q >/dev/null
on xvtx "for kv in $MIN; do echo \$kv >> /opt/xpam/config/config.txt; done; cd /opt/xpam-installer && export $MIN AUTO_INSTALL=1 XPAM_SKIP_SELF_UPDATE=1; timeout 1800 bash ./xpamctl.sh install > /root/install2.log 2>&1"
check 'XPAM installed and running' "wait_for \"on xvtx 'docker ps --format \\\"{{.Names}} {{.Status}}\\\"' | grep -q '^xpam_core .*(healthy)'\" 60"
check 'the SSH/RDP service runs' "wait_for \"on xvtx 'docker ps --format \\\"{{.Names}} {{.Status}}\\\"' | grep -q '^xpam_secureconnection .*(healthy)'\" 30"

say "an account with a password"
CANARY="canary-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
on xvtx "$CORE_SHELL" <<EOF >/dev/null
from orgs.utils import set_current_org; from orgs.models import Organization; set_current_org(Organization.default())
from assets.models import Host, Platform; from accounts.models import Account; from django.db import transaction
with transaction.atomic():
    h = Host.objects.create(name='vault-host', address='192.0.2.20', platform=Platform.objects.get(name='Linux'))
Account.objects.create(asset=h, name='root', username='root', secret_type='password', secret='$CANARY')
EOF
SECRET_BEFORE=$(on xvtx 'grep ^SECRET_KEY= /opt/xpam/config/config.txt | cut -d= -f2')
ACC="from orgs.utils import set_current_org; from orgs.models import Organization; set_current_org(Organization.default())
from accounts.models import Account; from accounts.models.mixins.vault import VAULT_SAVED_SECRET_MARK
a = Account.objects.get(name='root', asset__name='vault-host')"
check 'before: the account and SECRET_KEY are on the XPAM server' "[[ -n '$SECRET_BEFORE' && \$(printf '%s\nprint(a.secret)\n' \"\$ACC\" | on xvtx \"$CORE_SHELL\" | tail -1) == $CANARY ]]"

say "a hardened Vault on the XPAM server (the default at install)"
load_vault xvtx
on xvtx "cd /opt/xpam-installer && timeout 1500 bash ./xpamctl.sh vault local > /root/local.log 2>&1"; echo "local exit $?"
check 'local Vault set up and XPAM connected to it' "on xvtx 'grep -q \"secrets are in Vault\" /root/local.log' && on xvtx 'docker ps --format {{.Names}}' | grep -qx xpam_vault"
check 'local: config.txt holds no secret' "! on xvtx 'grep -E \"^(SECRET_KEY|DB_PASSWORD|REDIS_PASSWORD|BOOTSTRAP_TOKEN)=.\" /opt/xpam/config/config.txt'"
check 'local: the unseal key is sealed with systemd-creds (no share readable in the file)' "[[ \$(on xvtx 'systemd-creds decrypt --name=xpam-vault-unseal /etc/xpam-vault/unseal.cred - | wc -l') == 3 ]] && on xvtx 'systemd-creds decrypt --name=xpam-vault-unseal /etc/xpam-vault/unseal.cred - | while read -r k; do grep -qF \"\$k\" /etc/xpam-vault/unseal.cred && exit 1; done; exit 0'"
check 'local: XPAM runs with its secrets from the local Vault' "wait_for \"on xvtx 'docker ps --format \\\"{{.Names}} {{.Status}}\\\"' | grep -q '^xpam_core .*(healthy)'\" 40"
check 'local: xpamctl vault verify passes (TLS 1.3, certificates, least privilege, nothing on disk)' "on xvtx 'cd /opt/xpam-installer && bash ./xpamctl.sh vault verify' > /tmp/xvt-verify-local.log 2>&1"
grep -E "FAIL|passed" /tmp/xvt-verify-local.log | head -8
docker restart xvtx >/dev/null
DK="import json
try:
    from settings.tasks.datakey import data_key_status
    print('dk', json.dumps(data_key_status()))
except Exception as e:
    print('dk error', type(e).__name__, e)"
DK_OUT=$(printf '%s\n' "$DK" | on xvtx "$CORE_SHELL" | grep '^dk ' | tail -1); echo "  $DK_OUT"
check 'local: the data key is in the local Vault (Transit); every value uses it' "grep -q '\"provider\": \"transit\"' <<<\"\$DK_OUT\" && ! grep -q '\"legacy\"' <<<\"\$DK_OUT\""
check 'local: after a reboot the local Vault unseals itself and XPAM starts' "wait_for \"on xvtx 'docker ps --format \\\"{{.Names}} {{.Status}}\\\"' 2>/dev/null | grep -q '^xpam_core .*(healthy)'\" 72"

say "Vault (the kit, one server)"
on xvtv "export $PW XPAM_VAULT_SHARES_FILE=/root/shares; bash /src/vault/xpam-vault.sh init --nodes $V --xpam $X > /root/init.log 2>&1"
check 'the Vault kit is set up' "on xvtv 'grep -q \"XPAM server $X\" /root/init.log'"
docker exec xvtv cat /opt/xpam-vault/out/xpam-vault-$X.enc | docker exec -i xvtx sh -c 'cat > /root/xpam-vault.enc'

say "xpamctl vault connect: move from the local Vault to the Vault server"
on xvtx "cd /opt/xpam-installer && export $PW && timeout 1500 bash ./xpamctl.sh vault connect /root/xpam-vault.enc -y > /root/connect.log 2>&1"; echo "connect exit $?"
check 'connect finished (moved from the local Vault)' "on xvtx 'grep -q \"secrets are in Vault\" /root/connect.log'"
check 'the local Vault is stopped' "! on xvtx 'docker ps --format {{.Names}}' | grep -qx xpam_vault"
check 'XPAM now uses the Vault server' "on xvtx 'grep -q \"^VAULT_HCP_HOST=https://$V:8200\" /opt/xpam/config/config.txt'"
check 'config.txt holds no secret' "! on xvtx 'grep -E \"^(SECRET_KEY|BOOTSTRAP_TOKEN|DB_PASSWORD|REDIS_PASSWORD|REDIS_KOKO_PASSWORD|BROWSER_KEY|CHAT_AI_DELEGATION_SECRET)=.\" /opt/xpam/config/config.txt'"
check 'the secrets are in memory only (/run, a tmpfs)' "on xvtx 'test -s /run/xpam/secrets/all.env && findmnt -no FSTYPE --target /run/xpam/secrets | grep -q tmpfs'"
check 'Vault has the same SECRET_KEY as before' "on xvtx 'grep -qx \"SECRET_KEY=$SECRET_BEFORE\" /run/xpam/secrets/all.env'"
check 'no container holds a secret in its settings (docker inspect)' "! on xvtx 'for c in \$(docker ps -q); do docker inspect \$c; done' | grep -qF '$SECRET_BEFORE'"
check "nor in Docker's files on disk" "! on xvtx 'grep -rlF \"$SECRET_BEFORE\" /var/lib/docker/containers/ 2>/dev/null' | grep -q ."
check 'each container gets only its own secrets (SSH/RDP service: no SECRET_KEY)' "on xvtx 'test -s /run/xpam/secrets/koko/env && ! grep -q ^SECRET_KEY= /run/xpam/secrets/koko/env && grep -q ^REDIS_PASSWORD= /run/xpam/secrets/koko/env'"
check 'XPAM runs with its secrets from Vault' "wait_for \"on xvtx 'docker ps --format \\\"{{.Names}} {{.Status}}\\\"' | grep -q '^xpam_core .*(healthy)'\" 40"
check 'the SSH/RDP service runs with its secrets from Vault' "wait_for \"on xvtx 'docker ps --format \\\"{{.Names}} {{.Status}}\\\"' | grep -q '^xpam_secureconnection .*(healthy)'\" 40"
check 'the database keeps only the marker' "[[ \$(printf '%s\nprint(a._secret == VAULT_SAVED_SECRET_MARK)\n' \"\$ACC\" | on xvtx \"$CORE_SHELL\" | tail -1) == True ]]"
check 'XPAM still reads the password (docker exec too: the secrets file is read by every process)' "[[ \$(printf '%s\nprint(a.secret)\n' \"\$ACC\" | on xvtx \"$CORE_SHELL\" | tail -1) == $CANARY ]]"
STATUS_OUT=$(on xvtx 'cd /opt/xpam-installer && bash ./xpamctl.sh vault status' 2>&1)
check 'status: nothing left in config.txt, no account secret in the database' "grep -q 'in config.txt   none' <<<\"\$STATUS_OUT\" && grep -q 'in the database: 0' <<<\"\$STATUS_OUT\""
CONSOLE="from django.test import Client; from users.models import User
c = Client(HTTP_HOST='localhost'); c.force_login(User.objects.get(username='admin'))
evil = '{\"VAULT_HCP_HOST\": \"https://evil:8200\"}'
h = c.patch('/api/v1/settings/setting/?category=hcp', data=evil, content_type='application/json').status_code
r = c.post('/api/v1/settings/vault/restore/').status_code
t = c.post('/api/v1/settings/vault/hcp/testing/', data=evil, content_type='application/json').status_code
print(f'console hcp={h} restore={r} test={t}')"
CODES=$(printf '%s\n' "$CONSOLE" | on xvtx "$CORE_SHELL" | grep '^console ' | tail -1); echo "  $CODES"
check 'console: the vault settings cannot be changed' "grep -q 'hcp=403' <<<'$CODES'"
check 'console: secrets cannot be restored into the database' "grep -q 'restore=403' <<<'$CODES'"
check 'console: Test checks the configured Vault (not the address given)' "grep -q 'test=200' <<<'$CODES'"
DK_OUT=$(printf '%s\n' "$DK" | on xvtx "$CORE_SHELL" | grep '^dk ' | tail -1); echo "  $DK_OUT"
check 'the data key moved too: every value now uses the Vault server Transit key' "on xvtx 'grep -q \"^VAULT_TRANSIT_MOUNT=xpam-transit\" /opt/xpam/config/config.txt' && grep -q '\"provider\": \"transit\"' <<<\"\$DK_OUT\" && ! grep -q '\"legacy\"' <<<\"\$DK_OUT\""
check 'xpamctl vault verify passes against the Vault server' "on xvtx 'cd /opt/xpam-installer && bash ./xpamctl.sh vault verify' > /tmp/xvt-verify.log 2>&1"
grep -E "FAIL|passed" /tmp/xvt-verify.log | head -8

say "the installer keeps the Vault values"
KOKO_PW=$(on xvtx 'grep ^REDIS_KOKO_PASSWORD= /run/xpam/secrets/all.env | cut -d= -f2')
on xvtx 'cd /opt/xpam-installer && bash -c ". scripts/utils.sh; ensure_config_secret REDIS_KOKO_PASSWORD 32; ensure_config_secret BROWSER_KEY 32"' >/dev/null 2>&1
check 'an upgrade step does not create new secrets' "on xvtx 'grep -qx \"REDIS_KOKO_PASSWORD=$KOKO_PW\" /run/xpam/secrets/all.env' && ! on xvtx 'grep -E \"^(REDIS_KOKO_PASSWORD|BROWSER_KEY)=.\" /opt/xpam/config/config.txt'"

say "reboot"
docker restart xvtx >/dev/null
check 'after a reboot the secrets are read from Vault again and XPAM starts' "wait_for \"on xvtx 'docker ps --format \\\"{{.Names}} {{.Status}}\\\"' 2>/dev/null | grep -q '^xpam_core .*(healthy)'\" 60"

say "Vault unreachable at boot"
on xvtv 'docker stop xpam_vault >/dev/null'
docker restart xvtx >/dev/null; sleep 60
check 'XPAM waits (it does not start without its secrets)' "! on xvtx 'docker ps --format \"{{.Names}} {{.Status}}\"' 2>/dev/null | grep -q '^xpam_core .*(healthy)'"
check 'and no new secret was created' "! on xvtx 'grep -E \"^SECRET_KEY=.\" /opt/xpam/config/config.txt'"
on xvtv 'docker start xpam_vault >/dev/null'; sleep 5
docker exec xvtv head -3 /root/shares | docker exec -i xvtv bash /src/vault/xpam-vault.sh unseal >/dev/null
check 'once Vault is back (unsealed), XPAM starts by itself' "wait_for \"on xvtx 'docker ps --format \\\"{{.Names}} {{.Status}}\\\"' 2>/dev/null | grep -q '^xpam_core .*(healthy)'\" 60"

say "SECRET_KEY rotation (with the data key: nobody signed out)"
SESS_NEW="from django.test import Client; from django.conf import settings; from users.models import User
c = Client(HTTP_HOST='localhost'); c.force_login(User.objects.get(username='admin'))
print('session', c.cookies[settings.SESSION_COOKIE_NAME].value)"
SESSION=$(printf '%s\n' "$SESS_NEW" | on xvtx "$CORE_SHELL" | grep '^session ' | tail -1 | cut -d' ' -f2)
SESS_CHECK="from django.test import Client; from django.conf import settings
c = Client(HTTP_HOST='localhost'); c.cookies[settings.SESSION_COOKIE_NAME] = '$SESSION'
print('profile', c.get('/api/v1/users/profile/').status_code)"
check 'before the rotation: a signed-in session works' "[[ -n '$SESSION' ]] && printf '%s\\n' \"\$SESS_CHECK\" | on xvtx \"$CORE_SHELL\" | grep '^profile 200' >/dev/null"
on xvtx 'cd /opt/xpam-installer && timeout 1200 bash ./xpamctl.sh rotate-secret-key -y > /root/rotate.log 2>&1'
check 'the new key is in Vault (not in config.txt)' "! on xvtx 'grep -qx \"SECRET_KEY=$SECRET_BEFORE\" /run/xpam/secrets/all.env' && ! on xvtx 'grep -E \"^SECRET_KEY=.\" /opt/xpam/config/config.txt'"
check 'the password is still readable after the rotation' "wait_for \"on xvtx 'docker ps --format \\\"{{.Names}} {{.Status}}\\\"' | grep -q '^xpam_core .*(healthy)'\" 40 && [[ \$(printf '%s\nprint(a.secret)\n' \"\$ACC\" | on xvtx \"$CORE_SHELL\" | tail -1) == $CANARY ]]"
check 'the same session is still signed in after the rotation' "printf '%s\\n' \"\$SESS_CHECK\" | on xvtx \"$CORE_SHELL\" | grep '^profile 200' >/dev/null"
check 'the previous key is kept as a fallback (in Vault)' "on xvtx 'grep -qx \"SECRET_KEY_PREVIOUS=$SECRET_BEFORE\" /run/xpam/secrets/all.env'"
check 'and it is back in Vault only' "[[ \$(printf '%s\nprint(a._secret == VAULT_SAVED_SECRET_MARK)\n' \"\$ACC\" | on xvtx \"$CORE_SHELL\" | tail -1) == True ]]"

say "disconnect"
on xvtx "cd /opt/xpam-installer && timeout 1200 bash ./xpamctl.sh vault disconnect -y > /root/disconnect.log 2>&1"
check 'disconnect: every value under SECRET_KEY again (no Vault needed to read anything)' "on xvtx 'grep -q \"^XPAM_DATA_KEY=legacy\" /opt/xpam/config/config.txt'"
check 'disconnect: the secrets are back in config.txt' "on xvtx 'grep -qE \"^SECRET_KEY=.\" /opt/xpam/config/config.txt'"
check 'XPAM runs without Vault' "wait_for \"on xvtx 'docker ps --format \\\"{{.Names}} {{.Status}}\\\"' | grep -q '^xpam_core .*(healthy)'\" 40"
check 'the password is back in the database and readable' "[[ \$(printf '%s\nprint(a._secret != VAULT_SAVED_SECRET_MARK and a.secret)\n' \"\$ACC\" | on xvtx \"$CORE_SHELL\" | tail -1) == $CANARY ]]"

echo "RESULT: $PASS/$((PASS+FAIL)) passed"
[[ $FAIL -eq 0 ]]
