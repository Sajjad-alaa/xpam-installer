#!/usr/bin/env bash
# Runs tests/jit/access_test.py on a throwaway stack: PostgreSQL, Redis, XPAM's core (the image to test) and a
# Debian SSH host as the target (xpam-test/linuxhost). Nothing of the live system is used.
#   tests/jit/access_run.sh [core-tag]
set -uo pipefail
TAG=${1:-v5.1.18-dev}
HERE=$(cd "$(dirname "$0")" && pwd)
NET=acctnet
cleanup() { docker rm -f accpg accredis acccore flowhost >/dev/null 2>&1; docker network rm $NET >/dev/null 2>&1; }
trap cleanup EXIT
cleanup
rnd() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
W=$(mktemp -d)
cat > "$W/env" <<EOF
SECRET_KEY=$(rnd)$(rnd)
BOOTSTRAP_TOKEN=$(rnd)
DB_ENGINE=postgresql
DB_HOST=accpg
DB_PORT=5432
DB_USER=postgres
DB_PASSWORD=$(rnd)
DB_NAME=jumpserver
REDIS_HOST=accredis
REDIS_PORT=6379
REDIS_PASSWORD=$(rnd)
EOF
. "$W/env"
ROOT_PASSWORD="R-$(rnd | cut -c1-20)"
docker network create $NET >/dev/null
docker run -d --name accpg --network $NET -e POSTGRES_PASSWORD="$DB_PASSWORD" -e POSTGRES_DB=jumpserver postgres:16.15-bookworm >/dev/null
docker run -d --name accredis --network $NET redis:7.4.10-bookworm redis-server --requirepass "$REDIS_PASSWORD" >/dev/null
docker run -d --name flowhost --network $NET -e ROOT_PASSWORD="$ROOT_PASSWORD" xpam-test/linuxhost:latest >/dev/null
sleep 5
docker run -d --name acccore --network $NET --env-file "$W/env" "xpam/core:$TAG" start web >/dev/null
rm -rf "$W"
for _ in $(seq 1 150); do
  docker exec acccore python3 -c "import urllib.request as u; u.urlopen('http://127.0.0.1:8080/api/health/', timeout=2)" >/dev/null 2>&1 && break
  sleep 3
done
docker cp "$HERE/access_test.py" acccore:/tmp/access_test.py
docker exec -e ROOT_PASSWORD="$ROOT_PASSWORD" -w /opt/jumpserver/apps acccore python /tmp/access_test.py 2>&1 | grep -vE "^\s*$|Warning|warn\(" | tail -60
