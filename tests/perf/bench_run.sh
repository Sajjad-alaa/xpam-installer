#!/usr/bin/env bash
# Performance benchmark of a core image on a throwaway stack (nothing of the live system is used):
#   tests/perf/bench_run.sh <core-image> [label]
# 1. seeds data and profiles the main endpoints in-process (seed_profile.py: time and SQL queries per call)
# 2. starts `start web` and loads it over HTTP (load.py: p50/p95/requests per second, BENCH_C concurrent clients)
# 3. reports the memory of the web processes, idle and after the load
# Experiments: BENCH_APPS=<apps dir> mounts a source tree over the image's code; BENCH_CORE_ARGS adds docker run
# arguments to the web container (e.g. -e FOO=bar); BENCH_PG_ARGS adds postgres -c settings.
# BENCH_PIN=1 pins the web server to CPUs 0-1, PostgreSQL to CPU 2 and the load client to CPU 3 (less noise).
set -uo pipefail
PIN_WEB=(); PIN_PG=(); PIN_LOAD=()
if [ "${BENCH_PIN:-0}" = 1 ]; then PIN_WEB=(--cpuset-cpus 0,1); PIN_PG=(--cpuset-cpus 2); PIN_LOAD=(--cpuset-cpus 3); fi
IMAGE=${1:?usage: bench_run.sh <core-image> [label]}
LABEL=${2:-$IMAGE}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET=xbench
cleanup() { docker rm -f xb-pg xb-redis xb-core >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; }
cleanup; trap cleanup EXIT
docker network create "$NET" >/dev/null
docker run -d --rm --name xb-redis --network "$NET" redis:7.4.10-bookworm >/dev/null
# shellcheck disable=SC2086
docker run -d --rm --name xb-pg "${PIN_PG[@]}" --network "$NET" -e POSTGRES_PASSWORD=testonly -e POSTGRES_DB=jumpserver \
  postgres:16.15-bookworm ${BENCH_PG_ARGS:-} >/dev/null
sleep 8
ENV=(-e SECRET_KEY=test-only-not-secret-0123456789abcdef -e BOOTSTRAP_TOKEN=testtoken0123456 -e DB_ENGINE=postgresql
     -e DB_HOST=xb-pg -e DB_PORT=5432 -e DB_USER=postgres -e DB_PASSWORD=testonly -e DB_NAME=jumpserver
     -e REDIS_HOST=xb-redis -e XPACK_ENABLED=true -e DEBUG=false)
MOUNT=()
[ -n "${BENCH_APPS:-}" ] && MOUNT=(-v "$BENCH_APPS":/opt/jumpserver/apps:ro)
echo "=== $LABEL"
docker run --rm --network "$NET" "${ENV[@]}" "${MOUNT[@]}" -v "$HERE/seed_profile.py":/tmp/seed_profile.py:ro \
  -v "$HERE/hotspots.py":/tmp/hotspots.py:ro -e BENCH_HOTSPOTS="${BENCH_HOTSPOTS:-0}" \
  --entrypoint bash "$IMAGE" -c 'cd /opt/jumpserver/apps && python manage.py migrate --noinput >/dev/null 2>&1;
    { cat /tmp/seed_profile.py; [ "$BENCH_HOTSPOTS" = 1 ] && cat /tmp/hotspots.py; } > /tmp/run.py;
    python manage.py shell < /tmp/run.py 2>/tmp/err.log | grep -E "^(SEED|PROFILE|HOT)";
    grep -E "Traceback|Error" /tmp/err.log | grep -vE "DEBU|Warning" | tail -5'
[ "${BENCH_HOTSPOTS:-0}" = 1 ] && exit 0
# shellcheck disable=SC2086
docker run -d --name xb-core "${PIN_WEB[@]}" --network "$NET" --network-alias core "${ENV[@]}" "${MOUNT[@]}" ${BENCH_CORE_ARGS:-} \
  "$IMAGE" start web >/dev/null
for i in $(seq 1 60); do
  docker exec xb-core sh -c 'exec 3<>/dev/tcp/127.0.0.1/8080' 2>/dev/null && \
    [ "$(docker run --rm --network "$NET" curlimages/curl:8.11.1 -s -o /dev/null -w '%{http_code}' http://core:8080/api/health/)" = 200 ] && break
  sleep 3
done
mem() { docker exec xb-core bash -c 'tot=0; n=0; for p in /proc/[0-9]*; do c=$(tr "\0" " " < $p/cmdline 2>/dev/null);
  if echo "$c" | grep -q "gunicorn"; then r=$(awk "/VmRSS/{print \$2}" $p/status); tot=$((tot+r)); n=$((n+1)); fi; done;
  echo "$n processes, $((tot/1024)) MB"'; }
echo "MEM idle: $(mem)"
docker run --rm "${PIN_LOAD[@]}" --network "$NET" -e BENCH_N="${BENCH_N:-300}" -e BENCH_C="${BENCH_C:-8}" \
  -v "$HERE/load.py":/tmp/load.py:ro --entrypoint python "$IMAGE" /tmp/load.py 2>&1 | grep -E "^LOAD|Error"
echo "MEM after load: $(mem)"
docker logs xb-core 2>&1 | grep -cE "Traceback" | sed 's/^/tracebacks in web log: /'
