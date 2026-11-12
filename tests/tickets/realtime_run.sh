#!/usr/bin/env bash
# Runs tests/tickets/realtime_test.py on a throwaway stack: PostgreSQL, Redis and XPAM's core (the image to test).
# Nothing of the live system is used.
#   tests/tickets/realtime_run.sh [core-tag]      (APPS=/opt/xpam-core/apps to test the source tree; KEEP=1 keeps the stack)
set -uo pipefail
TAG=${1:-rn}
HERE=$(cd "$(dirname "$0")" && pwd)
NET=rtnet
cleanup() { docker rm -f rtpg rtredis rtcore >/dev/null 2>&1; docker network rm $NET >/dev/null 2>&1; }
[[ "${KEEP:-0}" == 1 ]] || trap cleanup EXIT
cleanup
rnd() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
W=$(mktemp -d)
cat > "$W/env" <<EOF
SECRET_KEY=$(rnd)$(rnd)
BOOTSTRAP_TOKEN=$(rnd)
DB_ENGINE=postgresql
DB_HOST=rtpg
DB_PORT=5432
DB_USER=postgres
DB_PASSWORD=$(rnd)
DB_NAME=xpam
REDIS_HOST=rtredis
REDIS_PORT=6379
REDIS_PASSWORD=$(rnd)
EOF
. "$W/env"
docker network create $NET >/dev/null
docker run -d --name rtpg --network $NET -e POSTGRES_PASSWORD="$DB_PASSWORD" -e POSTGRES_DB=xpam postgres:16.15-bookworm >/dev/null
docker run -d --name rtredis --network $NET redis:7.4.10-bookworm redis-server --requirepass "$REDIS_PASSWORD" >/dev/null
sleep 5
# (APPS=<core apps folder>: test that source tree instead of the image's compiled code)
MOUNT=()
if [[ -n "${APPS:-}" ]]; then
  source "$HERE/../security/data_mounts.sh" "xpam/core:$TAG" "$APPS"; MOUNT=("${APPS_MOUNT[@]}")
fi
docker run -d --name rtcore --network $NET --env-file "$W/env" "${MOUNT[@]}" "xpam/core:$TAG" start web >/dev/null
rm -rf "$W"
for _ in $(seq 1 150); do
  docker exec rtcore python3 -c "import urllib.request as u; u.urlopen('http://127.0.0.1:8080/api/health/', timeout=2)" >/dev/null 2>&1 && break
  sleep 3
done
docker cp "$HERE/realtime_test.py" rtcore:/tmp/realtime_test.py
docker exec -w /opt/core/apps rtcore python /tmp/realtime_test.py 2>&1 | grep -E "^(PASS|FAIL)|passed$|Error|Traceback|^\s+File" | tail -40
status=${PIPESTATUS[0]}
echo "-- core log (ticket socket lines):"
docker logs rtcore 2>&1 | grep -iE "ticket.*(socket|announce)|ws/tickets|WebSocket refused|Traceback" | tail -10
exit "$status"
