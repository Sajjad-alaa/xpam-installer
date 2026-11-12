#!/usr/bin/env bash
# A test script run inside core (manage.py shell) with an image's Python packages, on a throwaway PostgreSQL and
# Redis (nothing of the live system is used). With a core-apps-dir the source tree is mounted over the image's code.
#   tests/security/unit_run.sh <core-image> <test-script.py> [core-apps-dir]
#   e.g. tests/security/unit_run.sh xpam/core:rn tests/security/oauth_flow_test.py
# (core's own Django tests cannot run under `manage.py test`: its settings build the database configuration
# without the TEST entry the test runner expects)
set -uo pipefail
IMAGE=${1:?usage: unit_run.sh <core-image> <test-script.py> [core-apps-dir]}
SCRIPT=$(cd "$(dirname "${2:?usage: unit_run.sh <core-image> <test-script.py> [core-apps-dir]}")" && pwd)/$(basename "$2")
APPS=${3:-}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET=xut
cleanup() { docker rm -f xut-pg xut-redis >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; }
cleanup
trap cleanup EXIT
docker network create "$NET" >/dev/null
docker run -d --rm --name xut-pg --network "$NET" -e POSTGRES_PASSWORD=testonly -e POSTGRES_DB=xpam postgres:16.15-bookworm >/dev/null
docker run -d --rm --name xut-redis --network "$NET" redis:7.4.10-bookworm redis-server --requirepass testonly >/dev/null
ENV=(-e SECRET_KEY=unit-test-secret-key-0000000000000000000000000000 -e BOOTSTRAP_TOKEN=unit-test-bootstrap-0000
     -e DB_ENGINE=postgresql -e DB_HOST=xut-pg -e DB_PORT=5432 -e DB_USER=postgres -e DB_PASSWORD=testonly -e DB_NAME=xpam
     -e REDIS_HOST=xut-redis -e REDIS_PORT=6379 -e REDIS_PASSWORD=testonly)
sleep 5
MOUNT=()
if [ -n "$APPS" ]; then
  source "$HERE/data_mounts.sh" "$IMAGE" "$APPS"; MOUNT=("${APPS_MOUNT[@]}")
fi
docker run --rm --network "$NET" "${ENV[@]}" "${MOUNT[@]}" -v "$SCRIPT":/tmp/unit_test_script.py:ro \
  --entrypoint bash "$IMAGE" -c 'cd /opt/core/apps && timeout 900 python manage.py migrate --noinput >/tmp/m.log 2>&1;
    echo "migrate: $(grep -c "Applying" /tmp/m.log) applied";
    timeout 900 python manage.py shell < /tmp/unit_test_script.py 2>/tmp/err.log; echo "test exit $?";
    grep -E "Traceback|Error" /tmp/err.log | grep -vE "DEBU|INFO|Warning" | tail -10'
