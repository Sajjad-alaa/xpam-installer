#!/usr/bin/env bash
# The containers that stay root (core, worker, secureconnection, gateway) start and work with the capabilities
# compose drops from them, on a throwaway stack (nothing of the live system is used).
#   tests/security/capdrop_run.sh [tag]
set -uo pipefail
TAG=${1:-rn}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="$HERE/../../compose"
NET=xcd
W=$(mktemp -d)
cleanup() { docker rm -f -v xcd-pg xcd-redis xcd-core xcd-worker xcd-sc xcd-gw >/dev/null 2>&1; docker network rm $NET >/dev/null 2>&1; rm -rf "$W"; }
trap cleanup EXIT
cleanup; W=$(mktemp -d)
# the cap_drop list of a compose file, as docker run arguments
drops() { awk '/cap_drop:/{f=1;next} f&&/^ *- [A-Z_]+$/{print "--cap-drop", $2; next} f{exit}' "$COMPOSE/$1"; }
rnd() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
cat > "$W/env" <<EOF
SECRET_KEY=$(rnd)$(rnd)
BOOTSTRAP_TOKEN=$(rnd)
DB_ENGINE=postgresql
DB_HOST=xcd-pg
DB_PORT=5432
DB_USER=postgres
DB_PASSWORD=$(rnd)
DB_NAME=xpam
REDIS_HOST=xcd-redis
REDIS_PORT=6379
REDIS_PASSWORD=$(rnd)
CORE_HOST=http://xcd-core:8080
EOF
. "$W/env"
docker network create $NET >/dev/null
docker run -d --name xcd-pg --network $NET -e POSTGRES_PASSWORD="$DB_PASSWORD" -e POSTGRES_DB=xpam postgres:16.15-bookworm >/dev/null
docker run -d --name xcd-redis --network $NET redis:7.4.10-bookworm redis-server --requirepass "$REDIS_PASSWORD" >/dev/null
sleep 5
SEC=(--security-opt no-new-privileges:true)
docker run -d --name xcd-core --network $NET --network-alias core --env-file "$W/env" "${SEC[@]}" $(drops core.yml) "xpam/core:$TAG" start web >/dev/null
for _ in $(seq 1 150); do
  docker exec xcd-core python3 -c "import urllib.request as u; u.urlopen('http://127.0.0.1:8080/api/health/', timeout=2)" >/dev/null 2>&1 && break
  sleep 3
done
docker run -d --name xcd-worker --network $NET --env-file "$W/env" "${SEC[@]}" $(drops worker.yml) "xpam/core:$TAG" start task >/dev/null
docker run -d --name xcd-sc --network $NET --env-file "$W/env" "${SEC[@]}" $(drops secureconnection.yml) "xpam/secureconnection:$TAG" >/dev/null
docker run -d --name xcd-gw --network $NET "${SEC[@]}" $(drops gateway.yml) "xpam/gateway:$TAG" >/dev/null
for c in xcd-worker xcd-sc xcd-gw; do
  for _ in $(seq 1 60); do
    st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' $c 2>/dev/null)
    case "$st" in healthy|none) break;; esac  # (none: no health check in the image, checked below)
    [ "$(docker inspect -f '{{.State.Running}}' $c)" = true ] || break
    sleep 5
  done
done
sleep 20  # (the worker and the gateway: started, then checked below)
ok=1
report() { printf '%s %s  [%s]\n' "$([ "$2" = 1 ] && echo PASS || echo FAIL)" "$1" "$3"; [ "$2" = 1 ] || ok=0; }
for c in xcd-core xcd-worker xcd-sc xcd-gw; do
  report "$c runs with its capabilities dropped" "$([ "$(docker inspect -f '{{.State.Running}}' $c)" = true ] && echo 1 || echo 0)" \
    "$(docker inspect -f '{{.HostConfig.CapDrop}}' $c)"
done
# (core, worker and gateway have their health checks in compose, not in the image: checked here directly)
health=$(docker exec xcd-core python3 -c "import urllib.request as u; print(u.urlopen('http://127.0.0.1:8080/api/health/', timeout=5).status)" 2>&1 | tail -1)
report "core answers its health check" "$([ "$health" = 200 ] && echo 1 || echo 0)" "$health"
sc=$(docker inspect -f '{{.State.Health.Status}}' xcd-sc 2>/dev/null)
report "secureconnection is healthy" "$([ "$sc" = healthy ] && echo 1 || echo 0)" "$sc"
conf=$(docker exec xcd-gw nginx -t 2>&1 | tail -1)
report "the gateway's configuration loads" "$(echo "$conf" | grep -q successful && echo 1 || echo 0)" "$conf"
via=$(docker run --rm --network $NET curlimages/curl:8.11.1 -s -o /dev/null -w '%{http_code}' -m 20 http://xcd-gw/api/health/)
report "a request through the gateway reaches core" "$([ "$via" = 200 ] && echo 1 || echo 0)" "$via"
raw=$(docker exec xcd-core python3 -c "import socket; socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP); print('ok')" 2>&1 | tail -1)
report "core can still open the ICMP socket of its ping and traceroute tools" "$([ "$raw" = ok ] && echo 1 || echo 0)" "$raw"
pong=$(docker exec xcd-worker sh -c 'cd /opt/core/apps && timeout 60 celery -A ops inspect ping 2>&1' | grep -c "pong")
report "the worker answers celery" "$([ "$pong" -ge 1 ] && echo 1 || echo 0)" "$pong pong"
[ "$ok" = 1 ] && echo "DONE all passed" || { echo "DONE with failures"; for c in xcd-sc; do echo "-- $c"; docker inspect -f "{{json .State.Health}}" $c | cut -c1-600; docker logs --tail 25 $c 2>&1 | grep -v "GET .*health" | tail -15; done; exit 1; }
