#!/usr/bin/env bash
# The PostgreSQL connection pool survives a database restart (as in a failover): core keeps pooled connections,
# so after PostgreSQL restarts every one of them is dead. With CONN_HEALTH_CHECKS each is checked when it leaves
# the pool and replaced. This sends authenticated API calls before, during and after a restart of PostgreSQL and
# fails if any call fails once the database is back.
#   tests/perf/pool_restart_test.sh <core-image>
set -uo pipefail
IMAGE=${1:?usage: pool_restart_test.sh <core-image>}
NET=xpool
cleanup() { docker rm -f xp-pg xp-redis xp-core >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; }
cleanup; trap cleanup EXIT
docker network create "$NET" >/dev/null
docker run -d --rm --name xp-redis --network "$NET" redis:7.4.10-bookworm >/dev/null
docker run -d --name xp-pg --network "$NET" -e POSTGRES_PASSWORD=testonly -e POSTGRES_DB=jumpserver postgres:16.15-bookworm >/dev/null
sleep 8
ENV=(-e SECRET_KEY=test-only-not-secret-0123456789abcdef -e BOOTSTRAP_TOKEN=testtoken0123456 -e DB_ENGINE=postgresql
     -e DB_HOST=xp-pg -e DB_PORT=5432 -e DB_USER=postgres -e DB_PASSWORD=testonly -e DB_NAME=jumpserver -e REDIS_HOST=xp-redis)
docker run --rm --network "$NET" "${ENV[@]}" --entrypoint bash "$IMAGE" -c 'cd /opt/core/apps && python manage.py migrate --noinput >/dev/null 2>&1
  echo "from users.models import User; u = User.objects.get(username=\"admin\"); u.set_password(\"Pool-Test-Pass-2026\"); u.is_first_login = False; u.save()" | python manage.py shell >/dev/null 2>&1'
docker run -d --name xp-core --network "$NET" --network-alias core "${ENV[@]}" "$IMAGE" start web >/dev/null
for i in $(seq 1 60); do [ "$(docker run --rm --network "$NET" curlimages/curl:8.11.1 -s -o /dev/null -w '%{http_code}' http://core:8080/api/health/)" = 200 ] && break; sleep 3; done
echo "pooled connections in PostgreSQL before the restart: $(docker exec xp-pg psql -U postgres -tAc "select count(*) from pg_stat_activity where datname='jumpserver'")"
docker run --rm --network "$NET" --entrypoint python "$IMAGE" -c '
import threading, time, requests
B = "http://core:8080"
tok = requests.post(B + "/api/v1/authentication/auth/", json={"username": "admin", "password": "Pool-Test-Pass-2026"}, timeout=30).json()["token"]
H = {"Authorization": "Bearer " + tok}
def burst(label, n=40):
    codes = {}
    for _ in range(n):
        try: c = requests.get(B + "/api/v1/users/users/?limit=10", headers=H, timeout=20).status_code
        except requests.RequestException as e: c = type(e).__name__
        codes[c] = codes.get(c, 0) + 1
    print(f"  {label:34s} {codes}", flush=True); return codes
burst("before the restart")
open("/tmp/go", "w").close()
' &
CLIENT=$!
sleep 12
echo "restarting PostgreSQL..."; docker restart -t 2 xp-pg >/dev/null
for i in $(seq 1 30); do docker exec xp-pg pg_isready -U postgres -q && break; sleep 1; done
echo "PostgreSQL is back"
wait $CLIENT
docker run --rm --network "$NET" --entrypoint python "$IMAGE" -c '
import requests, sys
B = "http://core:8080"
tok = requests.post(B + "/api/v1/authentication/auth/", json={"username": "admin", "password": "Pool-Test-Pass-2026"}, timeout=30).json()["token"]
H = {"Authorization": "Bearer " + tok}
bad = 0
for label in ("right after the restart", "a little later"):
    codes = {}
    for _ in range(60):
        try: c = requests.get(B + "/api/v1/users/users/?limit=10", headers=H, timeout=20).status_code
        except requests.RequestException as e: c = type(e).__name__
        codes[c] = codes.get(c, 0) + 1
        bad += c != 200
    print(f"  {label:34s} {codes}", flush=True)
print("RESULT", "PASS: every call after the restart succeeded" if not bad else f"FAIL: {bad} failed calls after the restart")
sys.exit(1 if bad else 0)'
rc=$?
echo "server errors in the web log: $(docker logs xp-core 2>&1 | grep -cE 'Traceback|OperationalError|InterfaceError')"
exit $rc
