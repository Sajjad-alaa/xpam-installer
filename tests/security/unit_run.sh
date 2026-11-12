#!/usr/bin/env bash
# Core's own Django unit tests (the source tree's tests, which the image does not ship) with the image's Python
# packages, on a throwaway PostgreSQL and Redis (nothing of the live system is used).
#   tests/security/unit_run.sh <core-image> <core-apps-dir> <test label>...
#   e.g. tests/security/unit_run.sh xpam/core:rn /opt/xpam-core/apps authentication.tests.test_oauth2_provider
set -uo pipefail
IMAGE=${1:?usage: unit_run.sh <core-image> <core-apps-dir> <test label>...}
APPS=${2:?usage: unit_run.sh <core-image> <core-apps-dir> <test label>...}
shift 2
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
source "$HERE/data_mounts.sh" "$IMAGE" "$APPS"
docker run --rm --network "$NET" "${ENV[@]}" "${APPS_MOUNT[@]}" --entrypoint bash "$IMAGE" -c \
  "cd /opt/core/apps && timeout 1800 python manage.py test --noinput -v 1 $* 2>&1 | grep -vE 'DEBU|INFO' | tail -40"
