#!/usr/bin/env bash
# XPAM account storage backends, end to end (tests/vault/backends_test.py) against:
#   HashiCorp Vault  — a real Vault 2.1.2 (TLS 1.3, client certificates required, certificate login, the kit's policy)
#   CyberArk Conjur  — a real Conjur Open Source 1.27.0 (XPAM's host owns its policy branch)
#   Delinea, Google  — mock servers following their documented APIs (tests/vault/mock_vendors.py)
# all on a throwaway Docker network with a throwaway PostgreSQL and Redis.
#   tests/vault/backends_run.sh [core-tag]      (CORE_SRC=/opt/xpam-core: use that source's backends)
set -uo pipefail
TAG=${1:-v5.1.17}
NET=tvnet
HERE="$(cd "$(dirname "$0")" && pwd)"
W=$(mktemp -d /dev/shm/tv.XXXXXX); chmod 755 "$W"
say() { echo "== $(date +%T) $*"; }
cleanup() {
  docker rm -f tvpg tvredis tvcore tvmock tvvault tvconjur tvconjurdb >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
  rm -rf "$W"
}
[[ "${KEEP:-}" == "1" ]] || trap cleanup EXIT
cleanup; W=$(mktemp -d /dev/shm/tv.XXXXXX); chmod 755 "$W"
rnd() { head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
docker network create --subnet 172.31.7.0/24 "$NET" >/dev/null
CORE_IP=172.31.7.10

say "database, Redis, XPAM core ($TAG)"
cat > "$W/core.env" <<EOF
SECRET_KEY=$(rnd)$(rnd)
BOOTSTRAP_TOKEN=$(rnd)
DB_ENGINE=postgresql
DB_HOST=tvpg
DB_PORT=5432
DB_USER=postgres
DB_PASSWORD=$(rnd)
DB_NAME=jumpserver
REDIS_HOST=tvredis
REDIS_PORT=6379
REDIS_PASSWORD=$(rnd)
LOG_LEVEL=ERROR
EOF
chmod 644 "$W/core.env"
. "$W/core.env"
docker run -d --name tvpg --network $NET -e POSTGRES_PASSWORD="$DB_PASSWORD" -e POSTGRES_DB=jumpserver postgres:16.15-bookworm >/dev/null
docker run -d --name tvredis --network $NET redis:7.4.10-bookworm redis-server --requirepass "$REDIS_PASSWORD" >/dev/null
sleep 5
docker run --rm --network $NET --env-file "$W/core.env" --entrypoint sh "xpam/core:$TAG" \
  -c 'cd /opt/jumpserver/apps && python manage.py migrate >/dev/null 2>&1 && echo migrated' | tail -1

say "mock Delinea and Google servers"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$W/gcp.key" 2>/dev/null
openssl pkey -in "$W/gcp.key" -pubout -out "$W/gcp.pub" 2>/dev/null
chmod 644 "$W/gcp.key" "$W/gcp.pub"
DLN_PW=$(rnd)
cp "$HERE/mock_vendors.py" "$W/"
docker run -d --name tvmock --network $NET -v "$W:/w:ro" --entrypoint /opt/py3/bin/python "xpam/core:$TAG" \
  /w/mock_vendors.py /w/gcp.pub xpam-app "$DLN_PW" >/dev/null

say "HashiCorp Vault (TLS 1.3, client certificates, certificate login)"
mkdir -p "$W/vc"
(cd "$W/vc"
 openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 -subj "/CN=test CA" \
   -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign" -keyout ca.key -out ca.crt 2>/dev/null
 for n in "node tvvault serverAuth,clientAuth DNS:tvvault" "client xpam-test clientAuth DNS:xpam"; do set -- $n
   openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=$2" -keyout $1.key -out $1.csr 2>/dev/null
   printf 'basicConstraints=critical,CA:FALSE\nsubjectAltName=%s\nextendedKeyUsage=%s\nkeyUsage=critical,digitalSignature\nauthorityKeyIdentifier=keyid\n' "$4" "$3" > $1.ext
   openssl x509 -req -in $1.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 30 -extfile $1.ext -out $1.crt 2>/dev/null
 done; rm -f *.csr *.ext *.srl; chmod 644 *; chown 100:1000 node.key)
cat > "$W/vault.hcl" <<'EOF'
ui = false
disable_mlock = true
api_addr = "https://tvvault:8200"
cluster_addr = "https://tvvault:8201"
listener "tcp" {
  address = "0.0.0.0:8200"
  tls_cert_file = "/c/node.crt"
  tls_key_file = "/c/node.key"
  tls_client_ca_file = "/c/ca.crt"
  tls_min_version = "tls13"
  tls_require_and_verify_client_cert = true
}
storage "raft" {
  path = "/vault/data"
  node_id = "tvvault"
}
EOF
chmod 644 "$W/vault.hcl"
docker run -d --name tvvault --network $NET --user 100:1000 --tmpfs /vault/data:uid=100,gid=1000 -e SKIP_SETCAP=1 -e SKIP_CHOWN=1 \
  -v "$W/vault.hcl:/vault/config/vault.hcl:ro" -v "$W/vc:/c:ro" hashicorp/vault:2.1.2 server >/dev/null
VE="-e VAULT_ADDR=https://tvvault:8200 -e VAULT_CACERT=/c/ca.crt -e VAULT_CLIENT_CERT=/c/node.crt -e VAULT_CLIENT_KEY=/c/node.key"
sleep 4
INIT=$(docker exec $VE tvvault vault operator init -key-shares=1 -key-threshold=1 -format=json)
KEY=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["unseal_keys_b64"][0])' "$INIT")
ROOT=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["root_token"])' "$INIT")
docker exec $VE tvvault vault operator unseal "$KEY" >/dev/null; sleep 4
V() { docker exec -i $VE -e VAULT_TOKEN="$ROOT" tvvault vault "$@"; }
V secrets enable -path=xpam -version=2 kv >/dev/null
V policy write xpam - >/dev/null <<'EOF'
path "xpam/data/orgs/*"     { capabilities = ["create", "read", "update", "patch", "delete"] }
path "xpam/metadata/orgs/*" { capabilities = ["create", "read", "update", "patch", "delete", "list"] }
path "xpam/data/accounts/*"     { capabilities = ["create", "read", "update", "patch", "delete"] }
path "xpam/metadata/accounts/*" { capabilities = ["create", "read", "update", "patch", "delete", "list"] }
path "auth/token/lookup-self" { capabilities = ["read"] }
path "auth/token/renew-self"  { capabilities = ["update"] }
path "auth/token/revoke-self" { capabilities = ["update"] }
EOF
V auth enable cert >/dev/null
V write auth/cert/certs/xpam-test certificate=@/c/ca.crt allowed_common_names=xpam-test token_policies=xpam \
  token_no_default_policy=true token_bound_cidrs=$CORE_IP/32 token_ttl=20m token_max_ttl=1h >/dev/null && echo "  vault ready"

say "CyberArk Conjur Open Source"
CDB_PW=$(rnd)
docker run -d --name tvconjurdb --network $NET -e POSTGRES_PASSWORD="$CDB_PW" postgres:16.15-bookworm >/dev/null
DATA_KEY=$(docker run --rm cyberark/conjur:1.27.0 data-key generate)
sleep 5
docker run -d --name tvconjur --network $NET -e DATABASE_URL="postgres://postgres:$CDB_PW@tvconjurdb/postgres" \
  -e CONJUR_DATA_KEY="$DATA_KEY" -e CONJUR_AUTHENTICATORS=authn cyberark/conjur:1.27.0 server >/dev/null
for i in $(seq 60); do docker exec tvconjur curl -sf -o /dev/null http://localhost/ 2>/dev/null && break; sleep 3; done
ADMIN_KEY=$(docker exec tvconjur conjurctl account create xpamtest 2>/dev/null | awk '/API key for admin/{print $NF}')
AT=$(docker exec tvconjur curl -s -H 'Accept-Encoding: base64' --data "$ADMIN_KEY" http://localhost/authn/xpamtest/admin/authenticate)
CONJUR_KEY=$(docker exec -i tvconjur curl -s -X POST -H "Authorization: Token token=\"$AT\"" --data-binary @- \
  http://localhost/policies/xpamtest/policy/root <<'EOF' | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["created_roles"]["xpamtest:host:xpam-server"]["api_key"])'
- !host xpam-server
- !policy
  id: xpam
  owner: !host xpam-server
EOF
)
[[ -n "$CONJUR_KEY" ]] && echo "  conjur ready"

say "backends"
run() { # extra env...
  docker rm -f tvcore >/dev/null 2>&1
  local src=()
  [[ -n "${CORE_SRC:-}" ]] && src=(-v "$CORE_SRC/apps/accounts/backends:/opt/jumpserver/apps/accounts/backends:ro")
  docker run --rm --name tvcore --network $NET --ip $CORE_IP --env-file "$W/core.env" -e VAULT_ENABLED=true "${src[@]}" "$@" \
    -v "$HERE/backends_test.py:/t/backends_test.py:ro" -v "$W/vc:/vc:ro" -v "$W:/w:ro" \
    --entrypoint /opt/py3/bin/python "xpam/core:$TAG" /t/backends_test.py 2>&1 | grep -E '^(PASS|FAIL|RESULT)|Error|Traceback'
}
run -e VAULT_BACKEND=hcp -e VAULT_HCP_HOST=https://tvdown:8200,https://tvvault:8200 -e VAULT_HCP_AUTH=cert \
  -e VAULT_HCP_CERT_ROLE=xpam-test -e VAULT_HCP_MOUNT_POINT=xpam -e VAULT_HCP_CA_FILE=/vc/ca.crt \
  -e VAULT_HCP_CLIENT_CERT_FILE=/vc/client.crt -e VAULT_HCP_CLIENT_KEY_FILE=/vc/client.key -e VAULT_HCP_TIMEOUT=3
run -e VAULT_BACKEND=cyberark -e VAULT_CYBERARK_URL=http://tvconjur -e VAULT_CYBERARK_ACCOUNT=xpamtest \
  -e VAULT_CYBERARK_LOGIN=host/xpam-server -e VAULT_CYBERARK_API_KEY="$CONJUR_KEY" -e VAULT_CYBERARK_POLICY=xpam
run -e VAULT_BACKEND=delinea -e VAULT_DELINEA_URL=http://tvmock:8301 -e VAULT_DELINEA_USERNAME=xpam-app \
  -e VAULT_DELINEA_PASSWORD="$DLN_PW" -e VAULT_DELINEA_FOLDER_ID=7 -e VAULT_DELINEA_TEMPLATE_ID=6003
GCP_JSON=$(python3 -c 'import json,sys; print(json.dumps({"type": "service_account", "project_id": "xpam-test", "private_key_id": "k1", "private_key": open(sys.argv[1]).read(), "client_email": "xpam@xpam-test.iam.gserviceaccount.com", "token_uri": "http://tvmock:8302/token"}))' "$W/gcp.key")
run -e VAULT_BACKEND=gcp -e VAULT_GCP_PROJECT=xpam-test -e VAULT_GCP_CREDENTIALS="$GCP_JSON" -e VAULT_GCP_API_URL=http://tvmock:8302/v1

say "several vaults: rules, mirrors, moving, external passwords, console lock"
CONNS=$(python3 - "$CONJUR_KEY" "$DLN_PW" "$GCP_JSON" <<'PY'
import json, sys
conjur_key, dln_pw, gcp_json = sys.argv[1:4]
print(json.dumps({
  "conjur": {"type": "cyberark", "config": {"VAULT_CYBERARK_URL": "http://tvconjur", "VAULT_CYBERARK_ACCOUNT": "xpamtest",
             "VAULT_CYBERARK_LOGIN": "host/xpam-server", "VAULT_CYBERARK_API_KEY": conjur_key, "VAULT_CYBERARK_POLICY": "xpam"}},
  "delinea": {"type": "delinea", "config": {"VAULT_DELINEA_URL": "http://tvmock:8301", "VAULT_DELINEA_USERNAME": "xpam-app",
              "VAULT_DELINEA_PASSWORD": dln_pw, "VAULT_DELINEA_FOLDER_ID": "7", "VAULT_DELINEA_TEMPLATE_ID": "6003"}},
  "gcp": {"type": "gcp", "config": {"VAULT_GCP_PROJECT": "xpam-test", "VAULT_GCP_CREDENTIALS": gcp_json,
          "VAULT_GCP_API_URL": "http://tvmock:8302/v1"}},
}))
PY
)
printf '%s' "$CONNS" > "$W/conns.json"; chmod 600 "$W/conns.json"   # (KEEP=1: rerun the routing stage alone)
docker rm -f tvcore >/dev/null 2>&1
docker run --rm --name tvcore --network $NET --ip $CORE_IP --env-file "$W/core.env" -e VAULT_ENABLED=true \
  -e VAULT_BACKEND=hcp -e VAULT_HCP_HOST=https://tvvault:8200 -e VAULT_HCP_AUTH=cert -e VAULT_HCP_CERT_ROLE=xpam-test \
  -e VAULT_HCP_MOUNT_POINT=xpam -e VAULT_HCP_CA_FILE=/vc/ca.crt -e VAULT_HCP_CLIENT_CERT_FILE=/vc/client.crt \
  -e VAULT_HCP_CLIENT_KEY_FILE=/vc/client.key -e XPAM_TEST_CONNECTIONS="$CONNS" \
  -v "$HERE/routing_test.py:/t/routing_test.py:ro" -v "$W/vc:/vc:ro" \
  --entrypoint /opt/py3/bin/python "xpam/core:$TAG" /t/routing_test.py 2>&1 | grep -E '^(PASS|FAIL|RESULT)|Error|Traceback'

say "what the vendors saw"
docker exec tvmock python3 -c "import urllib.request,json; print('delinea', json.load(urllib.request.urlopen('http://localhost:8301/_state'))['calls'], 'calls;', 'google', json.load(urllib.request.urlopen('http://localhost:8302/_state'))['calls'], 'calls')" 2>/dev/null
echo "a wrong Conjur key / Delinea password / Google key is refused:"
docker run --rm --network $NET --env-file "$W/core.env" -v "$W:/w:ro" --entrypoint /opt/py3/bin/python "xpam/core:$TAG" -c "
import sys; sys.path.insert(0, '/opt/jumpserver/apps')
import os; os.environ['DJANGO_SETTINGS_MODULE'] = 'jumpserver.settings'
import django; django.setup()
from accounts.backends.cyberark.service import ConjurClient
from accounts.backends.delinea.service import DelineaClient
from accounts.backends.gcp.service import GoogleSecretManagerClient
import json
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
print(' conjur ', ConjurClient('http://tvconjur', 'xpamtest', 'host/xpam-server', 'wrong', 'xpam').is_active())
print(' delinea', DelineaClient('http://tvmock:8301', 'xpam-app', 'wrong', 7, 6003).is_active())
other = rsa.generate_private_key(public_exponent=65537, key_size=2048).private_bytes(
    serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()).decode()
print(' google ', GoogleSecretManagerClient('xpam-test', json.dumps({'private_key': other, 'client_email': 'x@y', 'token_uri': 'http://tvmock:8302/token'}), api_url='http://tvmock:8302/v1').is_active())
" 2>&1 | grep -E "conjur|delinea|google"
