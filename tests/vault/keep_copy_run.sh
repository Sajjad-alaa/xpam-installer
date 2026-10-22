#!/usr/bin/env bash
# Runs tests/vault/keep_copy_test.py on a throwaway stack: PostgreSQL, Redis, a Vault (dev mode) and XPAM's core
# (the image to test) with account storage in Vault and VAULT_KEEP_DB_COPY. Vault is paused for the "down" phase.
# Nothing of the live system is used.
#   tests/vault/keep_copy_run.sh [core-tag]
set -uo pipefail
TAG=${1:-v5.1.19-dev}
HERE=$(cd "$(dirname "$0")" && pwd)
NET=kcnet
cleanup() { rm -rf "${W:-/nonexistent}"; docker unpause kcvault >/dev/null 2>&1; docker rm -f kcpg kcredis kcvault kccore >/dev/null 2>&1; docker network rm $NET >/dev/null 2>&1; }
[[ "${KEEP:-}" == "1" ]] || trap cleanup EXIT
cleanup
rnd() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
W=$(mktemp -d)
cat > "$W/env" <<EOF
SECRET_KEY=$(rnd)$(rnd)
BOOTSTRAP_TOKEN=$(rnd)
DB_ENGINE=postgresql
DB_HOST=kcpg
DB_PORT=5432
DB_USER=postgres
DB_PASSWORD=$(rnd)
DB_NAME=jumpserver
REDIS_HOST=kcredis
REDIS_PORT=6379
REDIS_PASSWORD=$(rnd)
VAULT_ENABLED=true
VAULT_BACKEND=hcp
VAULT_HCP_HOST=http://kcvault:8200
VAULT_HCP_TOKEN=$(rnd)
VAULT_HCP_AUTH=token
VAULT_HCP_MOUNT_POINT=pam
VAULT_HCP_TIMEOUT=3
VAULT_KEEP_DB_COPY=true
XPAM_DATA_KEY=legacy
EOF
. "$W/env"
docker network create $NET >/dev/null
docker run -d --name kcpg --network $NET -e POSTGRES_PASSWORD="$DB_PASSWORD" -e POSTGRES_DB=jumpserver postgres:16.15-bookworm >/dev/null
docker run -d --name kcredis --network $NET redis:7.4.10-bookworm redis-server --requirepass "$REDIS_PASSWORD" >/dev/null
docker run -d --name kcvault --network $NET --cap-add IPC_LOCK -e VAULT_DEV_ROOT_TOKEN_ID="$VAULT_HCP_TOKEN" \
  -e VAULT_DEV_LISTEN_ADDRESS=0.0.0.0:8200 hashicorp/vault:2.1.2 server -dev >/dev/null
sleep 5
healthy() {
  for _ in $(seq 1 150); do
    docker exec kccore python3 -c "import urllib.request as u; u.urlopen('http://127.0.0.1:8080/api/health/', timeout=2)" >/dev/null 2>&1 && return 0
    sleep 3
  done
  return 1
}
# (as on a server: installed first, then the local data key — its keyring table comes with the migrations)
docker run -d --name kccore --network $NET --env-file "$W/env" "xpam/core:$TAG" start web >/dev/null
healthy || { docker logs kccore 2>&1 | tail -20; exit 1; }
sed -i 's/^XPAM_DATA_KEY=legacy$/XPAM_DATA_KEY=local/' "$W/env"
docker rm -f kccore >/dev/null
docker run -d --name kccore --network $NET --env-file "$W/env" "xpam/core:$TAG" start web >/dev/null
rm -rf "$W"
healthy || { docker logs kccore 2>&1 | tail -20; exit 1; }
docker cp "$HERE/keep_copy_test.py" kccore:/tmp/keep_copy_test.py
run() { docker exec -w /opt/jumpserver/apps kccore python /tmp/keep_copy_test.py "$1" 2>&1 | grep -vE '^\s*$|Warning|warn\(' | tail -40; }
rc=0
run setup || rc=1
docker pause kcvault >/dev/null
run down || rc=1
docker unpause kcvault >/dev/null
run live > /tmp/kc-live.$$ &
live=$!
for _ in $(seq 60); do docker exec kccore test -f /tmp/keep_copy_ready && break; sleep 1; done
docker pause kcvault >/dev/null
docker exec kccore touch /tmp/keep_copy_paused
wait $live || rc=1
cat /tmp/kc-live.$$; rm -f /tmp/kc-live.$$
docker unpause kcvault >/dev/null
run up || rc=1
exit $rc
