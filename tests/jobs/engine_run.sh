#!/usr/bin/env bash
# Runs tests/jobs/engine_test.py on a throwaway stack: PostgreSQL, Redis, XPAM's core (the image to test), a Debian
# SSH host and a PostgreSQL server as the targets. Nothing of the live system is used.
#   tests/jobs/engine_run.sh [core-tag]
# The job centre's engine (commands, file upload, database queries, playbooks run for a user): the jobs work and
# report a result per server, and nothing a user writes in a job is run or read on the XPAM server itself.
set -uo pipefail
TAG=${1:-v5.1.41}
HERE=$(cd "$(dirname "$0")" && pwd)
NET=jobnet
cleanup() { docker rm -f -v jobpg jobredis jobcore jobhost jobtpg >/dev/null 2>&1; docker network rm $NET >/dev/null 2>&1; }
trap cleanup EXIT
cleanup
rnd() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
W=$(mktemp -d)
cat > "$W/env" <<ENV
SECRET_KEY=$(rnd)$(rnd)
BOOTSTRAP_TOKEN=$(rnd)
DB_ENGINE=postgresql
DB_HOST=jobpg
DB_PORT=5432
DB_USER=postgres
DB_PASSWORD=$(rnd)
DB_NAME=jumpserver
REDIS_HOST=jobredis
REDIS_PORT=6379
REDIS_PASSWORD=$(rnd)
ENV
. "$W/env"
ROOT_PASSWORD="R-$(rnd | cut -c1-20)"
TARGET_PG_PASSWORD="T-$(rnd | cut -c1-20)"
docker image inspect xpam-test/linuxhost:latest >/dev/null 2>&1 \
  || docker build -q -t xpam-test/linuxhost:latest -f "$HERE/../jit/linuxhost.Dockerfile" "$HERE/../jit" >/dev/null \
  || { echo "could not build xpam-test/linuxhost"; exit 1; }
docker network create $NET >/dev/null
docker run -d --name jobpg --network $NET -e POSTGRES_PASSWORD="$DB_PASSWORD" -e POSTGRES_DB=jumpserver postgres:16.15-bookworm >/dev/null
docker run -d --name jobredis --network $NET redis:7.4.10-bookworm redis-server --requirepass "$REDIS_PASSWORD" >/dev/null
docker run -d --name jobhost --network $NET -e ROOT_PASSWORD="$ROOT_PASSWORD" xpam-test/linuxhost:latest >/dev/null
docker run -d --name jobtpg --network $NET -e POSTGRES_PASSWORD="$TARGET_PG_PASSWORD" postgres:16.15-bookworm >/dev/null
sleep 5
# (the capabilities the worker runs with in an installation: compose/worker.yml)
docker run -d --name jobcore --network $NET --env-file "$W/env" \
  --cap-drop NET_RAW --cap-drop MKNOD --cap-drop AUDIT_WRITE --cap-drop SETFCAP --cap-drop SYS_CHROOT \
  --cap-drop NET_BIND_SERVICE --security-opt no-new-privileges "xpam/core:$TAG" start web >/dev/null
rm -rf "$W"
for _ in $(seq 1 150); do
  docker exec jobcore python3 -c "import urllib.request as u; u.urlopen('http://127.0.0.1:8080/api/health/', timeout=2)" >/dev/null 2>&1 && break
  sleep 3
done
docker cp "$HERE/engine_test.py" jobcore:/tmp/engine_test.py
docker exec -e ROOT_PASSWORD="$ROOT_PASSWORD" -e TARGET_PG_PASSWORD="$TARGET_PG_PASSWORD" -w /opt/core/apps jobcore \
  python /tmp/engine_test.py 2>&1 | grep --line-buffered -E "^(PASS|FAIL|INFO|DONE|Traceback|  File|[A-Za-z.]*Error)" | cut -c1-400
