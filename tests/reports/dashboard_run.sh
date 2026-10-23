#!/usr/bin/env bash
# Runs tests/reports/dashboard_test.py on a throwaway stack: PostgreSQL, Redis and XPAM's core (the image to test).
# Nothing of the live system is used.
#   tests/reports/dashboard_run.sh [core-tag]
set -uo pipefail
TAG=${1:-v5.1.19-dev}
HERE=$(cd "$(dirname "$0")" && pwd)
NET=cdnet
cleanup() { docker rm -f cdpg cdredis cdcore >/dev/null 2>&1; docker network rm $NET >/dev/null 2>&1; }
[[ "${KEEP:-}" == "1" ]] || trap cleanup EXIT
cleanup
rnd() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
W=$(mktemp -d)
cat > "$W/env" <<EOF
SECRET_KEY=$(rnd)$(rnd)
BOOTSTRAP_TOKEN=$(rnd)
DB_ENGINE=postgresql
DB_HOST=cdpg
DB_PORT=5432
DB_USER=postgres
DB_PASSWORD=$(rnd)
DB_NAME=jumpserver
REDIS_HOST=cdredis
REDIS_PORT=6379
REDIS_PASSWORD=$(rnd)
EOF
. "$W/env"
docker network create $NET >/dev/null
docker run -d --name cdpg --network $NET -e POSTGRES_PASSWORD="$DB_PASSWORD" -e POSTGRES_DB=jumpserver postgres:16.15-bookworm >/dev/null
docker run -d --name cdredis --network $NET redis:7.4.10-bookworm redis-server --requirepass "$REDIS_PASSWORD" >/dev/null
sleep 5
docker run -d --name cdcore --network $NET --env-file "$W/env" "xpam/core:$TAG" start web >/dev/null
rm -rf "$W"
for _ in $(seq 1 150); do
  docker exec cdcore python3 -c "import urllib.request as u; u.urlopen('http://127.0.0.1:8080/api/health/', timeout=2)" >/dev/null 2>&1 && break
  sleep 3
done
docker cp "$HERE/dashboard_test.py" cdcore:/tmp/dashboard_test.py
docker exec -w /opt/jumpserver/apps cdcore python /tmp/dashboard_test.py 2>&1 | grep -vE "^\s*$|Warning|warn\(|\[DEBU\]|\[INFO\]" | tail -60
