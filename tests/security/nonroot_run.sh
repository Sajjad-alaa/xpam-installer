#!/usr/bin/env bash
# The AI service and the database web console run as their own users (not root) on a throwaway stack: PostgreSQL,
# Redis, core, ai and webconnector (nothing of the live system is used). Each must register with core, report
# healthy, run its processes as its own user with no capabilities, and own the data it writes — also when its data
# folder starts out root's (an installation from before).
#   tests/security/nonroot_run.sh [tag]
set -uo pipefail
TAG=${1:-rn}
NET=xnr
W=$(mktemp -d)
cleanup() { docker rm -f xnr-pg xnr-redis xnr-core xnr-ai xnr-wc >/dev/null 2>&1; docker network rm $NET >/dev/null 2>&1; rm -rf "$W"; }
trap cleanup EXIT
cleanup; W=$(mktemp -d)
rnd() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
cat > "$W/env" <<EOF
SECRET_KEY=$(rnd)$(rnd)
BOOTSTRAP_TOKEN=$(rnd)
DB_ENGINE=postgresql
DB_HOST=xnr-pg
DB_PORT=5432
DB_USER=postgres
DB_PASSWORD=$(rnd)
DB_NAME=xpam
REDIS_HOST=xnr-redis
REDIS_PORT=6379
REDIS_PASSWORD=$(rnd)
CORE_HOST=http://xnr-core:8080
EOF
# (core and the AI service share the delegation key, as compose/ai.yml passes it)
DELEGATION=$(rnd)$(rnd)
printf 'CHAT_AI_DELEGATION_SECRET=%s\nPLATFORM_DELEGATION_KEY=%s\n' "$DELEGATION" "$DELEGATION" >> "$W/env"
. "$W/env"
# data folders as an older installation left them: root's, with a file inside
mkdir -p "$W/ai" "$W/wc/logs" "$W/certs"; echo old > "$W/ai/old.txt"; echo old > "$W/wc/logs/old.log"
docker network create $NET >/dev/null
docker run -d --name xnr-pg --network $NET -e POSTGRES_PASSWORD="$DB_PASSWORD" -e POSTGRES_DB=xpam postgres:16.15-bookworm >/dev/null
docker run -d --name xnr-redis --network $NET redis:7.4.10-bookworm redis-server --requirepass "$REDIS_PASSWORD" >/dev/null
sleep 5
docker run -d --name xnr-core --network $NET --env-file "$W/env" "xpam/core:$TAG" start web >/dev/null
for _ in $(seq 1 150); do
  docker exec xnr-core python3 -c "import urllib.request as u; u.urlopen('http://127.0.0.1:8080/api/health/', timeout=2)" >/dev/null 2>&1 && break
  sleep 3
done
docker run -d --name xnr-ai --network $NET --env-file "$W/env" --security-opt no-new-privileges:true \
  -v "$W/ai:/opt/ai/data" "xpam/ai:$TAG" >/dev/null
docker run -d --name xnr-wc --network $NET --env-file "$W/env" --security-opt no-new-privileges:true \
  -v "$W/wc:/opt/webconnector/data" -v "$W/certs:/opt/webconnector/data/certs:ro" "xpam/webconnector:$TAG" >/dev/null
for c in xnr-ai xnr-wc; do
  for _ in $(seq 1 60); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' $c 2>/dev/null)" = healthy ] && break
    [ "$(docker inspect -f '{{.State.Running}}' $c)" = true ] || break
    sleep 5
  done
done
ok=1
report() { printf '%s %s  [%s]\n' "$([ "$2" = 1 ] && echo PASS || echo FAIL)" "$1" "$3"; [ "$2" = 1 ] || ok=0; }
for spec in "xnr-ai:10003:/opt/ai/data" "xnr-wc:10004:/opt/webconnector/data"; do
  c=${spec%%:*}; rest=${spec#*:}; uid=${rest%%:*}; dir=${rest#*:}
  health=$(docker inspect -f '{{.State.Health.Status}}' $c 2>/dev/null)
  report "$c is healthy (registered with core)" "$([ "$health" = healthy ] && echo 1 || echo 0)" "$health"
  # the service's processes: PID 1 and its children (docker exec and health checks come from outside: parent 0)
  procs=$(docker exec $c sh -c 'for p in /proc/[0-9]*; do [ -r $p/status ] && awk -v p=${p#/proc/} "/^PPid:/{pp=\$2} /^Uid:/{u=\$2} /^CapEff:/{c=\$2} END{print p, pp, u, c}" $p/status; done' 2>/dev/null | awk '$1 == 1 || $2 != 0 {print $1, $3, $4}')
  bad=$(echo "$procs" | awk -v u=$uid '$2 != u || $3 != "0000000000000000"' | grep -v "^$" | wc -l)
  report "$c: every process runs as uid $uid with no capabilities" "$([ "$bad" = 0 ] && echo 1 || echo 0)" "$(echo "$procs" | head -4 | tr '\n' ';')"
  wrong=$(docker exec $c sh -c "find $dir -path $dir/certs -prune -o ! -uid $uid -print | head -3")
  report "$c: the data folder (including the old files) is its user's" "$([ -z "$wrong" ] && echo 1 || echo 0)" "$wrong"
  written=$(docker exec $c sh -c "find $dir -path $dir/certs -prune -o -type f -mmin -10 -print | head -3")
  report "$c: it writes its data" "$([ -n "$written" ] && echo 1 || echo 0)" "$(echo $written | cut -c1-120)"
done
[ "$ok" = 1 ] && echo "DONE all passed" || { echo "DONE with failures"; docker logs --tail 15 xnr-ai 2>&1 | tail -5; docker logs --tail 15 xnr-wc 2>&1 | tail -5; exit 1; }
