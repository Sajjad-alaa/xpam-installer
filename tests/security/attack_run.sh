#!/usr/bin/env bash
# The attack suite (tests/security/attack_test.py) on a throwaway database: Postgres, Redis and a
# core container (nothing of the live system is used).
#   tests/security/attack_run.sh <core-image> [core-apps-dir]
# With a core-apps-dir the source tree is mounted over the image's code; without it the image's own (compiled)
# code is tested as shipped.
set -uo pipefail
IMAGE=${1:?usage: attack_run.sh <core-image> [core-apps-dir]}
APPS=${2:-}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET=xat
cleanup() { docker rm -f xat-pg xat-redis >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; }
cleanup
trap cleanup EXIT
docker network create "$NET" >/dev/null
docker run -d --rm --name xat-redis --network "$NET" redis:7.4.10-bookworm >/dev/null
docker run -d --rm --name xat-pg --network "$NET" -e POSTGRES_PASSWORD=testonly -e POSTGRES_DB=jumpserver postgres:16.15-bookworm >/dev/null
sleep 8
ENV=(-e SECRET_KEY=test-only-not-secret-0123456789abcdef -e BOOTSTRAP_TOKEN=testtoken0123456 -e DB_ENGINE=postgresql
     -e DB_HOST=xat-pg -e DB_PORT=5432 -e DB_USER=postgres -e DB_PASSWORD=testonly -e DB_NAME=jumpserver
     -e REDIS_HOST=xat-redis -e XPACK_ENABLED=true)
MOUNT=()
if [ -n "$APPS" ]; then
  source "$HERE/data_mounts.sh" "$IMAGE" "$APPS"; MOUNT=("${APPS_MOUNT[@]}")
fi
docker run --rm --network "$NET" "${ENV[@]}" "${MOUNT[@]}" -v "$HERE/attack_test.py":/tmp/attack_test.py:ro \
  --entrypoint bash "$IMAGE" -c 'cd /opt/jumpserver/apps && timeout 900 python manage.py migrate --noinput >/tmp/m.log 2>&1;
    echo "migrate: $(grep -c "Applying" /tmp/m.log) applied";
    timeout 900 python manage.py shell < /tmp/attack_test.py 2>/tmp/err.log; echo "test exit $?";
    grep -E "Traceback|Error" /tmp/err.log | grep -vE "DEBU|INFO|Warning" | tail -15'
