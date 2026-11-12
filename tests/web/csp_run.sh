#!/usr/bin/env bash
# The admin console under its Content-Security-Policy on a throwaway stack: PostgreSQL, Redis, core, the console (web)
# and the gateway that sends the policy; Chromium from the browser image signs in with a session made for the test
# administrator (no password is typed) and visits the console's pages (tests/web/csp_test.py). Nothing of the live
# system is used.
#   tests/web/csp_run.sh [tag]
set -uo pipefail
TAG=${1:-rn}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET=xcsp
W=$(mktemp -d)
cleanup() { docker rm -f xcsp-pg xcsp-redis xcsp-core xcsp-web xcsp-gw >/dev/null 2>&1; docker network rm $NET >/dev/null 2>&1; rm -rf "$W"; }
trap cleanup EXIT
cleanup; W=$(mktemp -d)
rnd() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
cat > "$W/env" <<EOF
SECRET_KEY=$(rnd)$(rnd)
BOOTSTRAP_TOKEN=$(rnd)
DB_ENGINE=postgresql
DB_HOST=xcsp-pg
DB_PORT=5432
DB_USER=postgres
DB_PASSWORD=$(rnd)
DB_NAME=xpam
REDIS_HOST=xcsp-redis
REDIS_PORT=6379
REDIS_PASSWORD=$(rnd)
SECURITY_MFA_AUTH=0
DOMAINS=xcsp-gw
EOF
. "$W/env"
docker network create $NET >/dev/null
docker run -d --name xcsp-pg --network $NET -e POSTGRES_PASSWORD="$DB_PASSWORD" -e POSTGRES_DB=xpam postgres:16.15-bookworm >/dev/null
docker run -d --name xcsp-redis --network $NET redis:7.4.10-bookworm redis-server --requirepass "$REDIS_PASSWORD" >/dev/null
sleep 5
docker run -d --name xcsp-core --network $NET --network-alias core --env-file "$W/env" "xpam/core:$TAG" start web >/dev/null
docker run -d --name xcsp-web --network $NET --network-alias web "xpam/web:$TAG" >/dev/null
for _ in $(seq 1 150); do
  docker exec xcsp-core python3 -c "import urllib.request as u; u.urlopen('http://127.0.0.1:8080/api/health/', timeout=2)" >/dev/null 2>&1 && break
  sleep 3
done
docker run -d --name xcsp-gw --network $NET -e SERVER_NAME=xcsp-gw "xpam/gateway:$TAG" >/dev/null
sleep 8
# a session for the administrator, made by core itself (no password), and one asset so the tree has a node
COOKIE=$(docker exec -w /opt/core/apps xcsp-core python manage.py shell -c "
from django.conf import settings; settings.ALLOWED_HOSTS = list(settings.ALLOWED_HOSTS) + ['testserver']
from django.test import Client
from users.models import User
from assets.models import Host, Platform, Node
from orgs.models import Organization
from orgs.utils import set_current_org
org = Organization.default(); set_current_org(org)
Host.objects.get_or_create(name='csp-host', defaults=dict(address='10.0.0.9', platform=Platform.objects.get(name='Linux')))
User.objects.filter(username='admin').update(is_first_login=False)  # (past the first sign-in guide)
c = Client(); c.force_login(User.objects.get(username='admin'))
print('COOKIE', settings.SESSION_COOKIE_NAME, c.cookies[settings.SESSION_COOKIE_NAME].value)
" 2>/dev/null | awk '/^COOKIE /{print $2, $3}' | tail -1)
[ -n "$COOKIE" ] || { echo "no session"; exit 1; }
echo "policy: $(docker run --rm --network $NET curlimages/curl:8.11.1 -sk -D - -o /dev/null https://xcsp-gw/web/ | grep -i '^content-security-policy' | cut -c1-120)"
docker run --rm --network $NET --shm-size 1g --tmpfs /tmp:size=1g -v /opt/xpam-secureconnection/browser:/src:ro \
  -v "$HERE:/t:ro" --entrypoint python3 xpam/browser:rn /t/csp_test.py https://xcsp-gw $COOKIE 2>&1 \
  | grep -E "^(PASS|FAIL)|DONE|script errors"
