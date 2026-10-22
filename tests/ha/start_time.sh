#!/usr/bin/env bash
# How long XPAM's core takes to answer after it starts: the first start of a build (full preparation) and a
# restart of the same build (quick start), on a throwaway database.
#   tests/ha/start_time.sh [tag]
set -uo pipefail
TAG=${1:-v5.1.17}
NET=tsnet
W=$(mktemp -d /dev/shm/ts.XXXXXX)
cleanup() { docker rm -f tspg tsredis tscore >/dev/null 2>&1; docker network rm $NET >/dev/null 2>&1; rm -rf "$W"; }
trap cleanup EXIT
cleanup; W=$(mktemp -d /dev/shm/ts.XXXXXX)
rnd() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
cat > "$W/env" <<EOF
SECRET_KEY=$(rnd)$(rnd)
BOOTSTRAP_TOKEN=$(rnd)
DB_ENGINE=postgresql
DB_HOST=tspg
DB_PORT=5432
DB_USER=postgres
DB_PASSWORD=$(rnd)
DB_NAME=jumpserver
REDIS_HOST=tsredis
REDIS_PORT=6379
REDIS_PASSWORD=$(rnd)
LOG_LEVEL=INFO
EOF
. "$W/env"
docker network create $NET >/dev/null
docker run -d --name tspg --network $NET -e POSTGRES_PASSWORD="$DB_PASSWORD" -e POSTGRES_DB=jumpserver postgres:16.15-bookworm >/dev/null
docker run -d --name tsredis --network $NET redis:7.4.10-bookworm redis-server --requirepass "$REDIS_PASSWORD" >/dev/null
docker volume create tsdata >/dev/null
sleep 5
measure() { # label [extra env]
  local t0 t1 extra=()
  [[ -n "${2:-}" ]] && extra=(-e "$2")
  docker rm -f tscore >/dev/null 2>&1
  t0=$(date +%s)
  docker run -d --name tscore --network $NET --env-file "$W/env" "${extra[@]}" -v tsdata:/opt/jumpserver/data "xpam/core:$TAG" start web >/dev/null
  for _ in $(seq 1 600); do
    docker exec tscore python3 -c "import urllib.request as u; u.urlopen('http://127.0.0.1:8080/api/health/', timeout=2)" >/dev/null 2>&1 && break
    sleep 1
  done
  t1=$(date +%s)
  echo "$1: $((t1 - t0)) s   ($(docker logs tscore 2>&1 | grep -oE 'quick start|Collect static files done' | head -1))"
}
measure "first start of this build (full preparation, incl. migrations of an empty database)"
measure "restart as before 5.1.17 (full preparation every time)" XPAM_FULL_PREPARE=1
measure "restart, same build"
measure "restart, same build (again)"
docker volume rm -f tsdata >/dev/null 2>&1
