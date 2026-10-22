#!/usr/bin/env bash
# Runs tests/jit/access_test.py on a throwaway stack: PostgreSQL, Redis, XPAM's core (the image to test) and a
# Debian SSH host as the target (xpam-test/linuxhost). Nothing of the live system is used.
#   tests/jit/access_run.sh [core-tag]
set -uo pipefail
TAG=${1:-v5.1.18-dev}
HERE=$(cd "$(dirname "$0")" && pwd)
TEST=${TEST:-access_test.py}   # (or flow_test.py: the same stack)
NET=acctnet
cleanup() { docker rm -f accpg accredis acccore flowhost flowpg >/dev/null 2>&1; docker network rm $NET >/dev/null 2>&1; }
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
TARGET_PG_PASSWORD="T-$(rnd | cut -c1-20)"
docker network create $NET >/dev/null
docker run -d --name accpg --network $NET -e POSTGRES_PASSWORD="$DB_PASSWORD" -e POSTGRES_DB=jumpserver postgres:16.15-bookworm >/dev/null
docker run -d --name accredis --network $NET redis:7.4.10-bookworm redis-server --requirepass "$REDIS_PASSWORD" >/dev/null
docker run -d --name flowhost --network $NET -e ROOT_PASSWORD="$ROOT_PASSWORD" xpam-test/linuxhost:latest >/dev/null
# (flow_test.py: a PostgreSQL server as a target too)
docker run -d --name flowpg --network $NET -e POSTGRES_PASSWORD="$TARGET_PG_PASSWORD" postgres:16.15-bookworm >/dev/null
sleep 5
docker run -d --name acccore --network $NET --env-file "$W/env" "xpam/core:$TAG" start web >/dev/null
rm -rf "$W"
for _ in $(seq 1 150); do
  docker exec acccore python3 -c "import urllib.request as u; u.urlopen('http://127.0.0.1:8080/api/health/', timeout=2)" >/dev/null 2>&1 && break
  sleep 3
done
docker cp "$HERE/$TEST" acccore:/tmp/$TEST
docker exec -e ROOT_PASSWORD="$ROOT_PASSWORD" -e TARGET_PG_PASSWORD="$TARGET_PG_PASSWORD" -w /opt/jumpserver/apps acccore python /tmp/$TEST 2>&1 | grep -vE "^\s*$|Warning|warn\(" | tail -60
