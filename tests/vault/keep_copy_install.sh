#!/usr/bin/env bash
# `xpamctl vault local --keep-db-copy` and `xpamctl vault keep-db-copy off|on` on a simulated XPAM server (5.1.19):
# account passwords in Vault with a copy in the database (local data key), read from the copy while Vault does not
# answer; off removes the copies and brings the data key back to Vault Transit; on fills them again.
#   tests/vault/keep_copy_install.sh [core-tag]    (the installer under test: this working tree)
set -uo pipefail
TAG=${1:-v5.1.19-dev}
BASE_TAG=${BASE_TAG:-v5.1.18}   # the other images (unchanged by this test)
NET=xkc; X=172.31.7.21
PASS=0; FAIL=0
check() { if eval "$2"; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }
on() { local n=$1; shift; docker exec -i "$n" bash -lc "$*"; }
wait_for() { for _ in $(seq "${2:-60}"); do eval "$1" && return 0; sleep 5; done; return 1; }
say() { echo "== $(date +%T) $*"; }
cleanup() { docker rm -f xkcx >/dev/null 2>&1; docker volume rm xkcx-docker >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; }
[[ "${KEEP:-}" == "1" ]] || trap cleanup EXIT
cleanup
MIN="XPAM_VAULT_MODE=none KOKO_ENABLED=0 CHEN_ENABLED=0 KAEL_ENABLED=0 BROWSER_ENABLED=0 WORKSPACE_ENABLED=0 WORKER_ENABLED=0 SERVER_SIZE=small XPAM_IMAGE_REGISTRY=local XPAM_VERSION=$TAG"
CORE_SHELL="docker exec -i xpam_core bash -c 'cd /opt/jumpserver/apps && python manage.py shell 2>/dev/null'"
cfg() { on xkcx "grep -E '^$1=' /opt/xpam/config/config.txt | tail -1 | cut -d= -f2-"; }
ready() { wait_for "on xkcx 'docker ps --format \"{{.Names}} {{.Status}}\"' | grep -q '^xpam_core .*(healthy)'" "${1:-40}"; }

say "server with XPAM $TAG (the installer of this working tree)"
docker network create --subnet 172.31.7.0/24 "$NET" >/dev/null
docker run -d --privileged --name xkcx --hostname xkcx --memory 2600m --memory-swap 2600m --cpus 2 --network $NET --ip $X \
  -v xkcx-docker:/var/lib/docker -v /opt/xpam-installer:/src:ro xpam-test/rocky-docker:9 >/dev/null
sleep 8
on xkcx 'systemctl start docker; git config --global --add safe.directory "*"'
on xkcx "cd /root && export $MIN XPAM_INSTALLER_REPO=/src AUTO_INSTALL=1 XPAM_SKIP_SELF_UPDATE=1; timeout 1200 bash /src/quick_start.sh > /root/install1.log 2>&1" || true
# (quick_start clones the committed installer: the working tree's scripts over it)
on xkcx "cp -a /src/scripts /src/xpamctl.sh /src/compose /src/vault /opt/xpam-installer/"
docker save "xpam/core:$TAG" "xpam/gateway:$BASE_TAG" "xpam/web:$BASE_TAG" postgres:16.15-bookworm redis:7.4.10-bookworm hashicorp/vault:2.1.2 \
  | docker exec -i xkcx docker load -q >/dev/null
on xkcx "docker tag xpam/gateway:$BASE_TAG xpam/gateway:$TAG; docker tag xpam/web:$BASE_TAG xpam/web:$TAG"
on xkcx "for kv in $MIN; do echo \$kv >> /opt/xpam/config/config.txt; done; cd /opt/xpam-installer && export $MIN AUTO_INSTALL=1 XPAM_SKIP_SELF_UPDATE=1; timeout 1800 bash ./xpamctl.sh install > /root/install2.log 2>&1"
check 'XPAM runs' "ready 60"

say "an account with a password, then the local Vault with --keep-db-copy"
PW="P-$(head -c 18 /dev/urandom | base64 | tr -dc A-Za-z0-9)"
printf '%s\n' "from django.conf import settings; settings.ALLOWED_HOSTS = list(settings.ALLOWED_HOSTS) + ['testserver']
from rest_framework.test import APIClient
from orgs.models import Organization; from orgs.utils import set_current_org; org = Organization.default(); set_current_org(org)
from users.models import User; from assets.models import Platform, Node
A = APIClient(); A.force_authenticate(User.objects.get(username='admin')); H = {'HTTP_X_JMS_ORG': str(org.id)}
r = A.post('/api/v1/assets/hosts/', {'name': 'kc-01', 'address': '10.0.0.5', 'platform': Platform.objects.get(name='Linux').id, 'nodes': [str(Node.org_root().id)], 'protocols': [{'name': 'ssh', 'port': 22}], 'accounts': [{'name': 'root', 'username': 'root', 'secret_type': 'password', 'secret': '$PW'}]}, format='json', **H)
print('host', r.status_code)" | on xkcx "$CORE_SHELL" | grep '^host'
acct() { printf '%s\n' "import os
from accounts.models import Account; from accounts.models.mixins.vault import VAULT_SAVED_SECRET_MARK as M
a = Account.all_objects.get(name='root', asset__name='kc-01') if hasattr(Account, 'all_objects') else Account._base_manager.get(name='root', asset__name='kc-01')
print('acct', 'marker' if a._secret == M else 'plain', 'copy' if a._secret_copy else 'nocopy', 'ok' if a.secret == '$PW' else 'wrong')" \
  | on xkcx "$CORE_SHELL" | grep '^acct' | cut -d' ' -f2-; }
on xkcx "cd /opt/xpam-installer && timeout 1500 bash ./xpamctl.sh vault local --keep-db-copy > /root/local.log 2>&1"
grep_log() { on xkcx "grep -q \"$2\" /root/$1"; }
check 'the local Vault is connected' "grep_log local.log 'secrets are in Vault'"
check 'the log says: in Vault, with a copy in the database (1 kept)' "grep_log local.log 'with a copy in the database (1 kept)'"
check 'config: VAULT_KEEP_DB_COPY=true, the local data key' "[[ \$(cfg VAULT_KEEP_DB_COPY) == true && \$(cfg XPAM_DATA_KEY) == local ]]"
S=$(acct); echo "  account: $S"
check 'the account: marker in the database, a copy, the password read' "[[ '$S' == 'marker copy ok' ]]"
check 'xpamctl vault status shows the database copy' "on xkcx 'cd /opt/xpam-installer && bash ./xpamctl.sh vault status' | grep -q 'database copy   yes'"

say "Vault does not answer"
on xkcx "docker pause xpam_vault >/dev/null"
S=$(acct); echo "  account: $S"
check 'Vault paused: the password is read from the copy' "[[ '$S' == 'marker copy ok' ]]"
on xkcx "docker unpause xpam_vault >/dev/null"

say "keep-db-copy off, then on"
on xkcx "cd /opt/xpam-installer && timeout 900 bash ./xpamctl.sh vault keep-db-copy off > /root/off.log 2>&1"
on xkcx "cat /root/off.log" | sed 's/^/  /'
check 'off: in Vault only, the data key back to Vault Transit' "grep_log off.log 'in Vault only (copies removed)' && [[ \$(cfg VAULT_KEEP_DB_COPY) == false && \$(cfg XPAM_DATA_KEY) == transit ]]"
ready
S=$(acct); echo "  account: $S"
check 'off: no copy, the password read from Vault' "[[ '$S' == 'marker nocopy ok' ]]"
on xkcx "cd /opt/xpam-installer && timeout 900 bash ./xpamctl.sh vault keep-db-copy on > /root/on.log 2>&1"
on xkcx "cat /root/on.log" | sed 's/^/  /'
check 'on: the local data key, the copy filled' "grep_log on.log 'with a copy in the database (1 kept)' && [[ \$(cfg XPAM_DATA_KEY) == local ]]"
ready
S=$(acct); echo "  account: $S"
check 'on: a copy, the password read' "[[ '$S' == 'marker copy ok' ]]"
check 'config.txt holds no secret' "! on xkcx 'grep -qE \"^(SECRET_KEY|DB_PASSWORD|REDIS_PASSWORD)=.+\" /opt/xpam/config/config.txt'"
echo "RESULT: $PASS/$((PASS+FAIL)) passed"
[[ $FAIL -eq 0 ]]
