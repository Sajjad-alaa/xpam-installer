#!/usr/bin/env bash
# XPAM Vault kit rehearsal: the real xpam-vault.sh flow on three simulated Vault servers (privileged Rocky
# Linux containers with their own Docker), an XPAM server and a stranger machine (both plain containers).
#   tests/vault/kit_test.sh          (xpam/core:<tag> local; the simulated servers pull hashicorp/vault:2.1.2)
# Checks: init / join / unseal, 3-node Raft, TLS and client-certificate refusals, firewall, XPAM login and
# policy, address binding, administrators cannot read or escalate, audit log, restart, leader loss,
# snapshot, audit fail-closed.
set -uo pipefail
CORE_TAG=${1:-v5.1.16}
NET=xvk; N1=172.31.8.11; N2=172.31.8.12; N3=172.31.8.13; XP=172.31.8.21; ST=172.31.8.99
PASS=0; FAIL=0
check() { if eval "$2"; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }
on() { local n=$1; shift; docker exec "$n" bash -lc "$*"; }
wait_for() { for _ in $(seq "${2:-60}"); do eval "$1" && return 0; sleep 3; done; return 1; }
say() { echo "== $(date +%T) $*"; }
cleanup() {
  docker rm -f xvk1 xvk2 xvk3 xvkx xvks >/dev/null 2>&1
  docker volume rm xvk1-docker xvk2-docker xvk3-docker >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
}
[[ "${KEEP:-}" == "1" ]] || trap cleanup EXIT
cleanup
export XPAM_VAULT_PASSPHRASE="Kit-$(head -c 32 /dev/urandom | tr -dc A-Za-z0-9 | head -c 20)"
export XPAM_VAULT_BUNDLE_PASSPHRASE="Bundle-$(head -c 32 /dev/urandom | tr -dc A-Za-z0-9 | head -c 20)"
PW="XPAM_VAULT_PASSPHRASE=$XPAM_VAULT_PASSPHRASE XPAM_VAULT_BUNDLE_PASSPHRASE=$XPAM_VAULT_BUNDLE_PASSPHRASE XPAM_VAULT_ALLOW_SWAP=1"
K=/opt/xpam-vault
# a Rocky Linux image with Docker already installed saves ~20 minutes of package downloads per run
NODE_IMAGE=rockylinux/rockylinux:9-ubi-init
docker image inspect xpam-test/rocky-docker:9 >/dev/null 2>&1 && NODE_IMAGE=xpam-test/rocky-docker:9

# the Vault image: from the host (VAULT_FS_TAR, `docker export` of a hashicorp/vault:2.1.2 container) or pulled
load_vault() {
  if [[ -s "${VAULT_FS_TAR:-}" ]]; then
    docker exec -i "$1" docker import --change 'ENTRYPOINT ["docker-entrypoint.sh"]' --change 'CMD ["server", "-dev"]' \
      --change 'USER vault' --change 'ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
      --change 'ENV NAME=vault' - hashicorp/vault:2.1.2 < "${VAULT_FS_TAR}" >/dev/null
  else
    on "$1" "for i in 1 2 3 4 5; do timeout 300 docker pull -q hashicorp/vault:2.1.2 >/dev/null 2>&1 && break; sleep 5; done"
  fi
}

say "servers"
docker network create --subnet 172.31.8.0/24 "$NET" >/dev/null
node() { # name ip
  docker run -d --privileged --name "$1" --hostname "$1" --memory 450m --memory-swap 450m --cpus 1 \
    --network "$NET" --ip "$2" -v "$1-docker:/var/lib/docker" -v /opt/xpam-installer:/src:ro \
    "$NODE_IMAGE" >/dev/null
}
node xvk1 $N1; node xvk2 $N2; node xvk3 $N3
docker run -d --name xvkx --network "$NET" --ip $XP --entrypoint sleep "xpam/core:$CORE_TAG" infinity >/dev/null
docker run -d --name xvks --network "$NET" --ip $ST --entrypoint sleep "xpam/core:$CORE_TAG" infinity >/dev/null
sleep 8
for n in xvk1 xvk2 xvk3; do
  on $n 'command -v docker >/dev/null && { systemctl start docker; exit 0; }; for i in $(seq 20); do dnf -y -q install dnf-plugins-core iptables-nft iproute python3 openssl tar procps-ng >/dev/null 2>&1 && break; sleep 10; done
    dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo >/dev/null 2>&1
    for i in $(seq 10); do dnf -y -q install docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null 2>&1 && break; sleep 10; done
    mkdir -p /etc/docker; echo "{\"features\":{\"containerd-snapshotter\":false}}" > /etc/docker/daemon.json
    systemctl enable --now docker >/dev/null 2>&1' &
done; wait
sleep 3
load_vault xvk1 & load_vault xvk2 & load_vault xvk3 & wait
check 'the simulated Vault servers have Docker and the Vault image' "on xvk3 'docker image inspect hashicorp/vault:2.1.2' >/dev/null"

say "init on the first Vault server"
# XPAM_VAULT_SHARES_FILE: the test keeps the key shares (the kit normally only shows them once)
on xvk1 "export $PW XPAM_VAULT_SHARES_FILE=/root/shares; bash /src/vault/xpam-vault.sh init --nodes $N1,$N2,$N3 --xpam $XP --admin-ips $ST > /root/init.log 2>&1"; echo "init exit $?"
check 'init finished and Vault 1 is unsealed' "on xvk1 'grep -q \"XPAM server $XP\" /root/init.log' && [[ \$(on xvk1 \"curl -s --cacert $K/certs/ca.crt --cert $K/certs/node.crt --key $K/certs/node.key https://$N1:8200/v1/sys/seal-status\" | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"sealed\"])') == False ]]"
check 'five key shares, written only where the test asked' "[[ \$(on xvk1 'wc -l < /root/shares') == 5 ]]"
check 'no root token is kept anywhere' "! on xvk1 'grep -rqa \"hvs\\.\" $K /root/init.log'"
check 'the CA key and admin key are stored only encrypted' "on xvk1 'test -s $K/kit/ca.key.enc && test -s $K/kit/admin.key.enc && ! ls $K/kit/*.key 2>/dev/null | grep -q .'"
check 'the bundles are encrypted' "! on xvk1 'gzip -t $K/out/xpam-vault-$XP.enc' 2>/dev/null && ! on xvk1 'grep -qa PRIVATE $K/out/*.enc'"

say "join the other two"
for n in 2 3; do ip=172.31.8.1$n
  docker exec xvk1 cat $K/out/xpam-vault-node-$ip.enc | docker exec -i xvk$n sh -c 'cat > /root/node.enc'
  on xvk$n "export $PW; bash /src/vault/xpam-vault.sh join /root/node.enc > /root/join.log 2>&1"
  docker exec xvk1 head -3 /root/shares | docker exec -i xvk$n bash /src/vault/xpam-vault.sh unseal >/dev/null
done
check 'join refuses a wrong bundle passphrase' "! on xvk2 'XPAM_VAULT_BUNDLE_PASSPHRASE=wrong XPAM_VAULT_DIR=/tmp/x bash /src/vault/xpam-vault.sh join /root/node.enc' >/dev/null 2>&1"
STATUS="export $PW; bash /src/vault/xpam-vault.sh status"
wait_for "[[ \$(on xvk1 '$STATUS' 2>/dev/null | grep -c ' voter') == 3 ]]" 40
check 'three Vault servers, all voting, one leader' "[[ \$(on xvk1 '$STATUS' | grep -c ' voter') == 3 && \$(on xvk1 '$STATUS' | grep -c ' leader ') == 1 ]]"
check 'every server unsealed' "[[ \$(on xvk1 '$STATUS' | grep -c ' unsealed') == 3 ]]"

say "the XPAM server"
docker exec xvk1 cat $K/out/xpam-vault-$XP.enc | docker exec -i -e XPAM_VAULT_BUNDLE_PASSPHRASE xvkx sh -c 'mkdir -p /v && openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass env:XPAM_VAULT_BUNDLE_PASSPHRASE | tar xzf - -C /v'
docker cp xvkx:/v - 2>/dev/null | docker exec -i xvks tar xf - -C / 2>/dev/null   # the stranger "steals" XPAM's certificate
cat > /tmp/xvk_probe.py <<'EOF'
import json, os, ssl, sys, requests, urllib3
urllib3.disable_warnings()
env = dict(l.strip().split("=", 1) for l in open("/v/vault.env") if "=" in l)
addrs = env["VAULT_ADDRS"].split(",")
def session(cert=("/v/client.crt", "/v/client.key"), verify="/v/ca.crt"):
    s = requests.Session(); s.verify = verify; s.cert = cert; return s
def code(fn):
    try: return fn().status_code
    except requests.exceptions.SSLError: return "tls-refused"
    except requests.exceptions.ConnectionError: return "unreachable"
op = sys.argv[1]
base = addrs[int(os.environ.get("NODE", "0"))]
s = session()
if op == "login":
    r = s.post(base + "/v1/auth/cert/login", json={"name": env["VAULT_ROLE"]}, timeout=10)
    print(r.status_code)
    if r.status_code == 200:
        open("/tmp/tok", "w").write(r.json()["auth"]["client_token"])
        print(json.dumps({"policies": r.json()["auth"]["policies"], "ttl": r.json()["auth"]["lease_duration"]}))
elif op == "do":
    m, path = sys.argv[2], sys.argv[3]
    body = json.loads(sys.argv[4]) if len(sys.argv) > 4 else None
    h = {"X-Vault-Token": open("/tmp/tok").read()}
    print(code(lambda: s.request(m, base + "/v1/" + path, json=body, headers=h, timeout=10)))
elif op == "read":
    h = {"X-Vault-Token": open("/tmp/tok").read()}
    print(s.get(base + "/v1/" + sys.argv[2], headers=h, timeout=10).json()["data"]["data"]["secret"])
elif op == "tls":
    variant = sys.argv[2]
    if variant == "nocert":
        print(code(lambda: session(cert=None).get(base + "/v1/sys/health", timeout=5)))
    elif variant == "tls12":
        ctx = ssl.create_default_context(cafile="/v/ca.crt"); ctx.load_cert_chain("/v/client.crt", "/v/client.key")
        ctx.maximum_version = ssl.TLSVersion.TLSv1_2
        import http.client
        host = base.split("//")[1].split(":")[0]
        try:
            c = http.client.HTTPSConnection(host, 8200, context=ctx, timeout=5); c.request("GET", "/v1/sys/health")
            print(c.getresponse().status)
        except Exception: print("tls-refused")
    elif variant == "ok":
        try:
            r = s.get(base + "/v1/sys/health", timeout=5); print(r.status_code, r.json().get("version") == "")
        except requests.exceptions.SSLError: print("tls-refused")
        except requests.exceptions.ConnectionError: print("unreachable")
EOF
docker cp /tmp/xvk_probe.py xvkx:/probe.py; docker cp /tmp/xvk_probe.py xvks:/probe.py; rm -f /tmp/xvk_probe.py
P() { local c=$1; shift; docker exec "$c" python3 /probe.py "$@" 2>/dev/null | head -1; }
check 'TLS 1.3 with the XPAM certificate works, version not revealed' "[[ \$(docker exec xvkx python3 /probe.py tls ok 2>/dev/null) == '200 True' ]]"
check 'no client certificate: refused' "[[ \$(P xvkx tls nocert) == tls-refused ]]"
check 'TLS 1.2: refused' "[[ \$(P xvkx tls tls12) == tls-refused ]]"
check 'XPAM logs in with its certificate' "[[ \$(P xvkx login) == 200 ]]"
check 'its token has only the xpam policy, 20 minutes' "docker exec xvkx python3 /probe.py login 2>/dev/null | tail -1 | grep -q '\"policies\": \[\"xpam\"\], \"ttl\": 1200'"
CANARY="canary-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
check 'XPAM writes an account secret' "[[ \$(P xvkx do POST xpam/data/orgs/o1/assets/a1/accounts/x1 '{\"data\":{\"secret\":\"$CANARY\"}}') == 200 ]]"
check 'and reads it back (through another Vault server)' "[[ \$(NODE=1 docker exec -e NODE=1 xvkx python3 /probe.py read xpam/data/orgs/o1/assets/a1/accounts/x1 2>/dev/null) == $CANARY ]]"
check 'XPAM writes its startup secrets' "[[ \$(P xvkx do POST xpam-startup/data/config '{\"data\":{\"SECRET_KEY\":\"x\"}}') == 200 ]]"
check 'XPAM cannot destroy startup history' "[[ \$(P xvkx do POST xpam-startup/destroy/config '{\"versions\":[1]}') == 403 ]]"
check 'XPAM cannot delete startup metadata' "[[ \$(P xvkx do DELETE xpam-startup/metadata/config) == 403 ]]"
check 'XPAM cannot list mounts, create tokens or change its login' "[[ \$(P xvkx do GET sys/mounts) == 403 && \$(P xvkx do POST auth/token/create '{}') == 403 && \$(P xvkx do POST auth/cert/certs/xpam-172-31-8-21 '{\"token_policies\":[\"vault-admin\"]}') == 403 ]]"
check 'XPAM cannot disable the audit log' "[[ \$(P xvkx do DELETE sys/audit/file) == 403 ]]"

say "a stranger with XPAM's stolen certificate"
check 'from its own address (allowed through the firewall as an admin workstation): login refused' "[[ \$(P xvks login) == 403 ]]"
docker exec xvkx cat /tmp/tok | docker exec -i xvks sh -c 'cat > /tmp/tok'
check "XPAM's stolen token from another address: refused" "[[ \$(P xvks do GET xpam/data/orgs/o1/assets/a1/accounts/x1) == 403 ]]"
on xvk1 "iptables -D XPAM-VAULT -p tcp --dport 8200 -s $ST -j RETURN"
check 'a machine not on the allow-list cannot reach Vault at all (firewall)' "[[ \$(P xvks tls ok) == unreachable ]]"
on xvk1 "$K/firewall.sh"

say "administrators"
# a helper on Vault 1: logs in with the admin certificate (kit passphrase), prints the HTTP status of one call
docker exec -i xvk1 sh -c 'cat > /root/adm.sh; chmod 700 /root/adm.sh' <<'ADM'
#!/usr/bin/env bash
. /opt/xpam-vault/kit.env; K=/opt/xpam-vault
XV_KIT_PW="$XPAM_VAULT_PASSPHRASE" openssl pkey -in $K/kit/admin.key.enc -passin env:XV_KIT_PW -out /dev/shm/a.key 2>/dev/null
C=(curl -s --cacert $K/certs/ca.crt --cert $K/kit/admin.crt --key /dev/shm/a.key)
T=$("${C[@]}" -X POST "https://$NODE_IP:8200/v1/auth/cert/login" -d '{"name":"vault-admin"}' | python3 -c 'import json,sys;print(json.load(sys.stdin)["auth"]["client_token"])')
printf 'X-Vault-Token: %s\n' "$T" > /dev/shm/a.hdr
"${C[@]}" -o /dev/null -w '%{http_code}' -H @/dev/shm/a.hdr -X "$1" "https://$NODE_IP:8200/v1/$2" ${3:+-d "$3"}
"${C[@]}" -o /dev/null -H @/dev/shm/a.hdr -X POST "https://$NODE_IP:8200/v1/auth/token/revoke-self"
rm -f /dev/shm/a.key /dev/shm/a.hdr
ADM
admin() { docker exec -e XPAM_VAULT_PASSPHRASE xvk1 /root/adm.sh "$@"; }
check "an administrator cannot read XPAM's secrets" "[[ \$(admin GET xpam/data/orgs/o1/assets/a1/accounts/x1) == 403 && \$(admin GET xpam-startup/data/config) == 403 ]]"
EVIL=$(python3 -c 'import json,sys; print(json.dumps({"certificate": "x", "allowed_common_names": ["xpam-evil"], "token_policies": ["xpam"], "token_bound_cidrs": [sys.argv[1] + "/32"]}))' $ST)
check 'an administrator cannot create a login for themselves' "[[ \$(admin POST auth/cert/certs/xpam-evil '$EVIL') == 403 ]]"
check 'an administrator cannot write policies or disable the audit log' "[[ \$(admin PUT sys/policies/acl/xpam '{\"policy\":\"\"}') == 403 && \$(admin DELETE sys/audit/file) == 403 ]]"
check 'an administrator can read the cluster state' "[[ \$(admin GET sys/storage/raft/configuration) == 200 ]]"
check 'an administrator can take a snapshot (backup)' "on xvk1 'export $PW; bash /src/vault/xpam-vault.sh snapshot /root/snap.bin' >/dev/null && on xvk1 'test -s /root/snap.bin'"

leader() { # the container of the current leader
  local ip
  ip=$(on xvk1 "$STATUS" 2>/dev/null | awk '/ leader /{print $1}' | sed 's/^vault-//; s/-/./g')
  case "$ip" in $N1) echo xvk1 ;; $N2) echo xvk2 ;; $N3) echo xvk3 ;; esac
}

say "audit log"
LN=$(leader)
check "the active server logs XPAM's read (who, what, from where)" "on $LN \"grep -h accounts/x1 $K/logs/audit.log\" | grep -q 'cert-xpam-172-31-8-21'"
check 'the audit log never contains the secret value' "! on xvk1 'grep -h $CANARY $K/logs/audit.log' && ! on xvk2 'grep -h $CANARY $K/logs/audit.log' && ! on xvk3 'grep -h $CANARY $K/logs/audit.log'"

say "restart and leader loss"
on xvk2 "docker restart xpam_vault >/dev/null"; sleep 5
# (status prints the seal states first; its admin part may fail while a leader is being elected)
st() { on xvk1 "$STATUS" 2>/dev/null; true; }
check 'a restarted Vault server is sealed' "wait_for \"st | grep -qE '$N2 +sealed'\" 20"
docker exec xvk1 sed -n 2,4p /root/shares | docker exec -i xvk2 bash /src/vault/xpam-vault.sh unseal >/dev/null
check 'it unseals with 3 shares and rejoins' "wait_for \"st | grep -qE '$N2 +unsealed'\" 20"
LN=$(leader)
on $LN "docker stop xpam_vault >/dev/null"
sleep 12
OTHER=0; [[ "$LN" == xvk1 ]] && OTHER=1
check 'with the leader down, XPAM still reads through another server' "[[ \$(docker exec -e NODE=$OTHER xvkx python3 /probe.py read xpam/data/orgs/o1/assets/a1/accounts/x1 2>/dev/null) == $CANARY ]]"
on $LN "docker start xpam_vault >/dev/null"; sleep 4
docker exec xvk1 head -3 /root/shares | docker exec -i $LN bash /src/vault/xpam-vault.sh unseal >/dev/null

say "audit fail-closed"
LN=$(leader)
on $LN "mv $K/logs/audit.log $K/logs/audit.log.1 && mkdir $K/logs/audit.log && docker kill -s HUP xpam_vault >/dev/null"; sleep 3
docker exec xvkx python3 /probe.py login >/dev/null 2>&1
check 'when the audit log cannot be written, Vault refuses to answer' "[[ \$(P xvkx do GET xpam/data/orgs/o1/assets/a1/accounts/x1) != 200 ]]"
on $LN "rmdir $K/logs/audit.log && mv $K/logs/audit.log.1 $K/logs/audit.log && docker kill -s HUP xpam_vault >/dev/null"; sleep 3
check 'and answers again once it can' "[[ \$(P xvkx login) == 200 ]]"

echo "RESULT: $PASS/$((PASS+FAIL)) passed"
[[ $FAIL -eq 0 ]]
