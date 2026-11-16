#!/usr/bin/env bash
# Runs tests/jobs/engine_test.py on a throwaway stack: PostgreSQL, Redis, XPAM's core (the image to test), a Debian
# SSH host and a PostgreSQL server as the targets. Nothing of the live system is used.
#   tests/jobs/engine_run.sh [core-tag]          RUNNER=1: the jobs run on the runner service (xpam/runner:<tag>)
# The job centre's engine (commands, file upload, database queries, playbooks run for a user): the jobs work and
# report a result per server, and nothing a user writes in a job is run or read on the XPAM server itself.
set -uo pipefail
TAG=${1:-v5.1.41}
TEST=${TEST:-engine_test.py}   # (or scripts_test.py: the same stack)
HERE=$(cd "$(dirname "$0")" && pwd)
NET=jobnet; RNET=jobrun; RUNNER=${RUNNER:-0}
cleanup() { docker rm -f -v jobpg jobredis jobcore jobhost jobtpg jobrunner >/dev/null 2>&1; docker network rm $NET $RNET >/dev/null 2>&1; }
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
RUNNER_ENABLED=$RUNNER
RUNNER_KEY=$(rnd)
ENV
. "$W/env"
ROOT_PASSWORD="R-$(rnd | cut -c1-20)"
TARGET_PG_PASSWORD="T-$(rnd | cut -c1-20)"
docker image inspect xpam-test/linuxhost:latest >/dev/null 2>&1 \
  || docker build -q -t xpam-test/linuxhost:latest -f "$HERE/../jit/linuxhost.Dockerfile" "$HERE/../jit" >/dev/null \
  || { echo "could not build xpam-test/linuxhost"; exit 1; }
docker network create $NET >/dev/null
docker network create $RNET >/dev/null
docker run -d --name jobpg --network $NET -e POSTGRES_PASSWORD="$DB_PASSWORD" -e POSTGRES_DB=jumpserver postgres:16.15-bookworm >/dev/null
docker run -d --name jobredis --network $NET redis:7.4.10-bookworm redis-server --requirepass "$REDIS_PASSWORD" >/dev/null
# (the targets are reachable from the core network and, like any server, from the runner's)
docker run -d --name jobhost --hostname jobhost --network $NET -e ROOT_PASSWORD="$ROOT_PASSWORD" xpam-test/linuxhost:latest >/dev/null
docker run -d --name jobtpg --network $NET -e POSTGRES_PASSWORD="$TARGET_PG_PASSWORD" postgres:16.15-bookworm >/dev/null
docker network connect $RNET jobhost; docker network connect $RNET jobtpg
if [[ "$RUNNER" == 1 ]]; then
  # (as compose/runner.yml: its own network, read-only, a few capabilities to run each job as its own user)
  docker run -d --name jobrunner --hostname runner --network $RNET --network-alias runner -e RUNNER_KEY="$RUNNER_KEY" \
    --read-only --tmpfs /tmp:size=256m --tmpfs /opt/core/data/share/ansible:size=512m,mode=0711 \
    --cap-drop ALL --cap-add SETUID --cap-add SETGID --cap-add CHOWN --cap-add KILL \
    --security-opt no-new-privileges --memory 1g --pids-limit 1024 "xpam/runner:$TAG" >/dev/null
fi
sleep 5
# (the capabilities the worker runs with in an installation: compose/worker.yml)
docker run -d --name jobcore --network $NET --env-file "$W/env" \
  --cap-drop NET_RAW --cap-drop MKNOD --cap-drop AUDIT_WRITE --cap-drop SETFCAP --cap-drop SYS_CHROOT \
  --cap-drop NET_BIND_SERVICE --security-opt no-new-privileges "xpam/core:$TAG" start web >/dev/null
# (the worker's place on the runner's network: the runner reaches gateway tunnels there)
docker network connect --alias jobs-worker $RNET jobcore
rm -rf "$W"
for _ in $(seq 1 150); do
  docker exec jobcore python3 -c "import urllib.request as u; u.urlopen('http://127.0.0.1:8080/api/health/', timeout=2)" >/dev/null 2>&1 && break
  sleep 3
done
docker cp "$HERE/$TEST" jobcore:/tmp/$TEST
docker exec -e ROOT_PASSWORD="$ROOT_PASSWORD" -e TARGET_PG_PASSWORD="$TARGET_PG_PASSWORD" -e RUNNER="$RUNNER" -w /opt/core/apps jobcore \
  python /tmp/$TEST 2>&1 | grep --line-buffered -E "^(PASS|FAIL|INFO|DONE|Traceback|  File|[A-Za-z.]*Error)" | cut -c1-400
if [[ "$RUNNER" == 1 ]]; then
  # what a job could have done on the runner itself
  for _ in $(seq 1 15); do   # (a stopped job is cleaned up within seconds)
    left=$(docker exec jobrunner sh -c 'ls /tmp/ctl-* 2>/dev/null; ls -A /opt/core/data/share/ansible /tmp/home 2>/dev/null | grep -v ":$" | grep .' | tr '\n' ' ')
    [[ -z "${left// /}" ]] && break; sleep 1
  done
  [[ -z "$left" ]] && echo "PASS nothing a job ran or left stays on the runner" || echo "FAIL the runner keeps: $left"
  docker exec jobrunner /opt/py3/bin/python -c "import socket; s=socket.create_connection(('jobpg', 5432), 3)" >/dev/null 2>&1 \
    && echo "FAIL the runner reaches XPAM's database" || echo "PASS the runner cannot reach XPAM's database"
  docker exec jobrunner /opt/py3/bin/python -c "import socket; s=socket.create_connection(('jobredis', 6379), 3)" >/dev/null 2>&1 \
    && echo "FAIL the runner reaches XPAM's Redis" || echo "PASS the runner cannot reach XPAM's Redis"
  docker exec jobrunner sh -c 'env | grep -E "SECRET_KEY|DB_PASSWORD|REDIS_PASSWORD|BOOTSTRAP"' >/dev/null \
    && echo "FAIL the runner holds XPAM secrets" || echo "PASS the runner holds no XPAM secret besides its key"
  [[ $(docker exec jobrunner awk '/^Uid:/{print $2}' /proc/1/status) == 0 ]] && \
    [[ -z "$(docker exec jobrunner sh -c 'ls /opt/core/apps | grep -v -x libs')" ]] \
    && echo "PASS the runner image carries no XPAM application code" || echo "FAIL the runner image carries application code"
  docker logs jobrunner 2>&1 | grep -vE '"GET /health' | tail -${RUNNER_LOG_LINES:-0} | sed 's/^/LOG /'
fi
