#!/usr/bin/env bash
# The API attack matrix (tests/security/api_matrix.py) on a throwaway database: Postgres, Redis and a core container
# of the given image with this core tree mounted (nothing of the live system is used).
#   tests/security/api_matrix_run.sh [core-image] [core-apps-dir]     output: $OUT (default /tmp/xpam-api-matrix.log)
set -uo pipefail
IMAGE=${1:-xpam/core:v5.1.24}
APPS=${2:-/opt/xpam-core/apps}
OUT=${OUT:-/tmp/xpam-api-matrix.log}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET=xam
cleanup() { docker rm -f xam-pg xam-redis >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; }
cleanup
trap cleanup EXIT
docker network create "$NET" >/dev/null
docker run -d --rm --name xam-redis --network "$NET" redis:7.4.10-bookworm >/dev/null
docker run -d --rm --name xam-pg --network "$NET" -e POSTGRES_PASSWORD=testonly -e POSTGRES_DB=jumpserver postgres:16.15-bookworm >/dev/null
sleep 8
ENV=(-e SECRET_KEY=test-only-not-secret-0123456789abcdef -e BOOTSTRAP_TOKEN=testtoken0123456 -e DB_ENGINE=postgresql
     -e DB_HOST=xam-pg -e DB_PORT=5432 -e DB_USER=postgres -e DB_PASSWORD=testonly -e DB_NAME=jumpserver
     -e REDIS_HOST=xam-redis -e XPACK_ENABLED=true)
docker run --rm --network "$NET" "${ENV[@]}" -v "$APPS":/opt/jumpserver/apps:ro -v "$HERE/api_matrix.py":/tmp/api_matrix.py:ro \
  --entrypoint bash "$IMAGE" -c 'cd /opt/jumpserver/apps && timeout 900 python manage.py migrate --noinput >/tmp/m.log 2>&1;
    echo "migrate: $(grep -c "Applying" /tmp/m.log) applied, last: $(tail -1 /tmp/m.log | cut -c1-100)";
    timeout 3000 python manage.py shell < /tmp/api_matrix.py 2>/tmp/err.log; echo "matrix exit $?"; grep -vE "DEBU|INFO|Warning|warn\(" /tmp/err.log | tail -25;
    echo "== server errors"; grep -A40 "Internal Server Error" /tmp/err.log | grep -E "Internal Server Error|^\S*Error|File \"/opt/jumpserver/apps"' \
  > "$OUT" 2>&1
grep -E '^(WORLD|ROUTES|READS|WRITES|DONE|ESCALATION|FUNC|migrate|matrix)' "$OUT"
echo "findings: $(grep -c '^FINDING' "$OUT")  (in $OUT)"
