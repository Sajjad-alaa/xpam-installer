#!/usr/bin/env bash
# XPAM high availability rehearsal, ACTIVE-ACTIVE: three simulated servers (privileged Rocky Linux containers with
# their own Docker, memory-capped), no witness — the three vote among themselves. XPAM runs on all three at once;
# Vault on the same three machines (co-located, auto-unseal). A host watchdog stops the test if the host runs low
# on memory (it shares the machine with other work).
#   tests/ha/rehearsal_aa.sh [tag]         (images xpam/core, xpam/gateway, xpam/postgresql-ha:<tag> local; VAULT_FS_TAR)
# Checks: every server serves; one database writer (the primary) and one main Redis (the Sentinels) used from every
# server over TLS with the cluster's app certificate; files copied between all servers; crash of the primary with
# the others serving on; the server coming back; a rolling upgrade (one version at a time on the database);
# back to one server.
set -uo pipefail
TAG=${1:-v5.1.17}
NET=xaa; A=172.31.11.11; B=172.31.11.12; C=172.31.11.13
NODES="xaaa xaab xaac"
MEM=${NODE_MEMORY:-1200m}
MIN_HOST_MB=${MIN_HOST_MB:-400}
PASS=0; FAIL=0
check() { if eval "$2"; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }
on() { local n=$1; shift; docker exec -i "$n" bash -lc "$*"; }
wait_for() { for _ in $(seq "${2:-60}"); do eval "$1" && return 0; sleep 5; done; return 1; }
say() { echo "== $(date +%T) $*"; }
cleanup() {
  [[ -n "${WATCHDOG:-}" ]] && kill "$WATCHDOG" 2>/dev/null
  docker rm -f $NODES >/dev/null 2>&1
  for n in $NODES; do docker volume rm "$n-docker" >/dev/null 2>&1; done
  docker network rm "$NET" >/dev/null 2>&1
}
[[ "${KEEP:-}" == "1" ]] || trap cleanup EXIT
cleanup
# the host watchdog: the simulated servers go first if the host itself runs short of memory
( while sleep 5; do
    avail=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
    if (( avail < MIN_HOST_MB )); then
      echo "WATCHDOG: host memory available ${avail} MB < ${MIN_HOST_MB} MB — stopping the simulated servers"
      docker rm -f $NODES >/dev/null 2>&1; exit 0
    fi
  done ) &
WATCHDOG=$!
export XPAM_HA_BUNDLE_PASSPHRASE="Bundle-$(head -c 32 /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)"
export XPAM_HA_PASSPHRASE="Cluster-$(head -c 32 /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)"
export XPAM_VAULT_PASSPHRASE="Kit-$(head -c 32 /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)"
export XPAM_VAULT_BUNDLE_PASSPHRASE="VB-$(head -c 32 /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)"
export XPAM_VAULT_RECOVERY_PASSPHRASE="Rec-$(head -c 32 /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)"
VPASS="XPAM_VAULT_PASSPHRASE=$XPAM_VAULT_PASSPHRASE XPAM_VAULT_BUNDLE_PASSPHRASE=$XPAM_VAULT_BUNDLE_PASSPHRASE XPAM_VAULT_RECOVERY_PASSPHRASE=$XPAM_VAULT_RECOVERY_PASSPHRASE XPAM_VAULT_ALLOW_SWAP=1"
PASSENV="XPAM_HA_BUNDLE_PASSPHRASE=$XPAM_HA_BUNDLE_PASSPHRASE XPAM_HA_PASSPHRASE=$XPAM_HA_PASSPHRASE $VPASS"
NODE_IMAGE=rockylinux/rockylinux:9-ubi-init
docker image inspect xpam-test/rocky-docker:9 >/dev/null 2>&1 && NODE_IMAGE=xpam-test/rocky-docker:9
MIN="XPAM_VAULT_MODE=none KOKO_ENABLED=0 CHEN_ENABLED=0 KAEL_ENABLED=0 BROWSER_ENABLED=0 WORKSPACE_ENABLED=0 WEB_ENABLED=0 WORKER_ENABLED=0 SERVER_SIZE=small XPAM_IMAGE_REGISTRY=local XPAM_VERSION=$TAG"
CERTS='--cacert /opt/xpam/config/ha/certs/ca.crt --cert /opt/xpam/config/ha/certs/node.crt --key /opt/xpam/config/ha/certs/node.key'
CORE_SHELL="docker exec -i xpam_core bash -c 'cd /opt/jumpserver/apps && python manage.py shell 2>/dev/null'"
PSQL='docker exec xpam_postgresql psql -U $(grep ^DB_USER= /opt/xpam/config/config.txt | cut -d= -f2) -d $(grep ^DB_NAME= /opt/xpam/config/config.txt | cut -d= -f2) -Atqc'
ip_of() { case $1 in xaaa) echo $A ;; xaab) echo $B ;; xaac) echo $C ;; esac; }
node_of() { case $1 in "$A") echo xaaa ;; "$B") echo xaab ;; "$C") echo xaac ;; esac; }
primary_ip() { # the database primary, as Patroni on any running server says
  local n
  for n in $NODES; do
    docker exec "$n" true 2>/dev/null || continue
    on "$n" "curl -s $CERTS --max-time 5 https://$(ip_of $n):8008/cluster" 2>/dev/null \
      | python3 -c 'import json,sys; print(next((m["host"] for m in json.load(sys.stdin)["members"] if m["role"]=="leader"), ""))' 2>/dev/null && return
  done
}
core_healthy() { on "$1" 'docker ps --format "{{.Names}} {{.Status}}"' 2>/dev/null | grep -q '^xpam_core .*(healthy)'; }
answers() { [[ $(on "$1" 'curl -sk -o /dev/null -w %{http_code} --max-time 4 https://127.0.0.1/api/health/' 2>/dev/null) == 200 ]]; }
django() { # node python — run in that server's core
  printf '%s\n' "$2" | on "$1" "$CORE_SHELL" 2>/dev/null
}

say "servers"
docker network create --subnet 172.31.11.0/24 "$NET" >/dev/null
for n in $NODES; do
  docker run -d --privileged --name "$n" --hostname "$n" --memory "$MEM" --memory-swap "$MEM" --cpus 2 \
    --network "$NET" --ip "$(ip_of $n)" -v "$n-docker:/var/lib/docker" -v /opt/xpam-installer:/src:ro "$NODE_IMAGE" >/dev/null
done
sleep 8
for n in $NODES; do
  on $n 'command -v docker >/dev/null && systemctl start docker; command -v git rsync sshd >/dev/null || dnf -y -q install git rsync openssh-server openssh-clients >/dev/null 2>&1; systemctl enable --now sshd >/dev/null 2>&1; git config --global --add safe.directory "*"'
done
check 'the simulated servers have their packages' "for n in $NODES; do on \$n 'command -v git rsync' >/dev/null || exit 1; done"

say "XPAM on A, B and C (reduced: core + gateway), one after the other (memory)"
install() {
  on "$1" "cd /root && export $MIN XPAM_INSTALLER_REPO=/src AUTO_INSTALL=1 XPAM_SKIP_SELF_UPDATE=1; timeout 1200 bash /src/quick_start.sh > /root/install1.log 2>&1" || true
  docker save "xpam/core:$TAG" "xpam/gateway:$TAG" "xpam/postgresql-ha:$TAG" postgres:16.15-bookworm redis:7.4.10-bookworm \
    gcr.io/etcd-development/etcd:v3.5.21 | docker exec -i "$1" docker load -q >/dev/null
  on "$1" "for kv in $MIN; do echo \$kv >> /opt/xpam/config/config.txt; done; cd /opt/xpam-installer && export $MIN AUTO_INSTALL=1 XPAM_SKIP_SELF_UPDATE=1; timeout 1800 bash ./xpamctl.sh install > /root/install2.log 2>&1"
}
for n in $NODES; do install $n; done
check 'XPAM installed and running on A, B and C' "for n in $NODES; do core_healthy \$n || exit 1; done"

say "Vault on the three servers (co-located, auto-unseal); A connected to it"
for n in $NODES; do
  docker exec -i "$n" docker import --change 'ENTRYPOINT ["docker-entrypoint.sh"]' --change 'CMD ["server", "-dev"]' \
    --change 'USER vault' --change 'ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
    --change 'ENV NAME=vault' - hashicorp/vault:2.1.2 < "${VAULT_FS_TAR}" >/dev/null
done
on xaaa "export $VPASS XPAM_VAULT_SHARES_FILE=/root/shares; bash /src/vault/xpam-vault.sh init --colocated --nodes $A,$B,$C --xpam $A,$B,$C > /root/vault-init.log 2>&1"
for n in xaab xaac; do ip=$(ip_of $n)
  docker exec xaaa cat /opt/xpam-vault/out/xpam-vault-node-$ip.enc | docker exec -i $n sh -c 'cat > /root/vnode.enc'
  on $n "export $VPASS; bash /src/vault/xpam-vault.sh join /root/vnode.enc > /root/vault-join.log 2>&1"
done
check 'Vault: three nodes, all unsealed' "wait_for \"[[ \\\$(on xaaa 'export $VPASS; bash /src/vault/xpam-vault.sh status' 2>/dev/null | grep -c ' unsealed') == 3 ]]\" 30"
docker exec xaaa cp /opt/xpam-vault/out/xpam-vault-$B.enc /root/vbB.enc
docker exec xaaa cp /opt/xpam-vault/out/xpam-vault-$C.enc /root/vbC.enc
on xaaa "cd /opt/xpam-installer && export $VPASS && timeout 1500 bash ./xpamctl.sh vault connect /opt/xpam-vault/out/xpam-vault-$A.enc -y > /root/vault-connect.log 2>&1"
check "A: XPAM's secrets are in Vault" "on xaaa 'grep -q \"secrets are in Vault\" /root/vault-connect.log'"

say "seed data on A"
on xaaa "$PSQL 'CREATE TABLE xpam_ha_rehearsal(v text); INSERT INTO xpam_ha_rehearsal VALUES (\$\$seed\$\$)'"

say "ha init on A: active-active, servers A, B, C (no witness)"
# (output captured first: `cmd | grep -q` fails under pipefail when grep stops reading early)
OUT2=$(on xaaa "cd /opt/xpam-installer && bash ./xpamctl.sh ha init --topology active-active --servers $A,$B -y" 2>&1)
check 'ha init refuses active-active with 2 servers' "[[ \$OUT2 == *'3 or 5 servers'* ]]"
OUTW=$(on xaaa "cd /opt/xpam-installer && bash ./xpamctl.sh ha init --topology active-passive --servers $A,$B,$C --witness 172.31.11.99 -y" 2>&1)
check 'ha init refuses a witness with 3 servers' "[[ \$OUTW == *'no witness is needed'* ]]"
on xaaa "cd /opt/xpam-installer && export $PASSENV && timeout 1800 bash ./xpamctl.sh ha init --topology active-active --servers $A,$B,$C --vault-bundle /root/vbB.enc,/root/vbC.enc -y > /root/ha-init.log 2>&1"
check 'A is the primary and serves' "[[ \$(primary_ip) == $A ]] && wait_for 'core_healthy xaaa' 60"
check 'a join bundle for each other server, encrypted, without secrets' "on xaaa 'test -s /opt/xpam/config/ha/xpam-ha-join-$B.enc && test -s /opt/xpam/config/ha/xpam-ha-join-$C.enc' && ! on xaaa 'grep -qa SECRET_KEY /opt/xpam/config/ha/xpam-ha-join-$B.enc'"

say "ha join on B, then C"
for n in xaab xaac; do ip=$(ip_of $n)
  docker exec xaaa cat /opt/xpam/config/ha/xpam-ha-join-$ip.enc | docker exec -i $n sh -c 'cat > /root/join.enc'
  on $n "cd /opt/xpam-installer && export $PASSENV && timeout 2400 bash ./xpamctl.sh ha join /root/join.enc -y > /root/ha-join.log 2>&1"; tail -1 <(on $n 'cat /root/ha-join.log')
done
check 'the three servers are in the cluster (one leader, two replicas streaming)' "wait_for \"[[ \\\$(on xaaa 'curl -s $CERTS https://$A:8008/cluster' | grep -o '\\\"state\\\": \\\"streaming\\\"' | wc -l) == 2 ]]\" 36"
check 'XPAM runs on all three servers' "wait_for 'core_healthy xaab && core_healthy xaac' 60 && core_healthy xaaa"
check 'each server answers as XPAM (health URL for the load balancer)' "wait_for 'answers xaaa && answers xaab && answers xaac' 24"
check "B's and C's XPAM use the primary's database (A), not their read-only copy" "django xaac 'from django.db import connection; c = connection.cursor(); c.execute(\"select inet_server_addr()::text, pg_is_in_recovery()\"); print(\"DB\", *c.fetchone())' | grep -q \"^DB $A/32 False\""
check 'a write made through C reaches the cluster (read on B)' "django xaac 'from django.db import connection; c = connection.cursor(); c.execute(\"insert into xpam_ha_rehearsal values (%s)\", [\"via-c\"]); connection.commit() if not connection.get_autocommit() else None' >/dev/null; wait_for \"on xaab \\\"\\\$PSQL 'select v from xpam_ha_rehearsal'\\\" | grep -qx via-c\" 6"
check 'one Redis for all: a value stored through B is read through C' "django xaab 'from django.core.cache import cache; cache.set(\"xpam-aa\", \"shared\", 300)' >/dev/null; django xaac 'from django.core.cache import cache; print(\"CACHE\", cache.get(\"xpam-aa\"))' | grep -q '^CACHE shared'"
sentinel_master() { on "$1" 'docker exec xpam_sentinel sh -c "REDISCLI_AUTH=\$(. /run/xpam-secrets/env 2>/dev/null; echo \$REDIS_PASSWORD) redis-cli --tls -p 26380 --cacert /tmp/xpam-tls/ca.crt --cert /tmp/xpam-tls/node.crt --key /tmp/xpam-tls/node.key SENTINEL get-master-addr-by-name xpam"' 2>/dev/null | head -1; }
check "the Sentinel's state on disk holds no password" "! on xaab 'grep -qE \"requirepass|auth-pass|sentinel-pass\" /data/xpam/redis/sentinel/state.conf' && on xaab 'test -s /data/xpam/redis/sentinel/state.conf'"
check 'the three Sentinels agree: the main Redis is on A' "[[ \$(sentinel_master xaaa) == $A && \$(sentinel_master xaab) == $A && \$(sentinel_master xaac) == $A ]]"
DBU=$(on xaab 'grep ^DB_USER= /opt/xpam/config/config.txt | cut -d= -f2'); DBN=$(on xaab 'grep ^DB_NAME= /opt/xpam/config/config.txt | cut -d= -f2')
login() { # from B to A's database as XPAM, with or without the app certificate
  on xaab "export PGPASSWORD=\$(grep ^DB_PASSWORD= /run/xpam/secrets/all.env | cut -d= -f2); docker run --rm --network host -e PGPASSWORD -e PGCONNECT_TIMEOUT=5 -v /opt/xpam/config/certs:/c:ro postgres:16.15-bookworm psql \"host=$A user=$DBU dbname=$DBN $1\" -Atqc 'select 1'" 2>/dev/null | grep -qx 1
}
check "another server logs in to the primary's database as XPAM with the app certificate (TLS)" "login 'sslmode=verify-ca sslrootcert=/c/db_ca.pem sslcert=/c/db_client.crt sslkey=/c/db_client.key'"
check 'and is refused without it (even with the password)' "! login 'sslmode=require'"
on xaab 'mkdir -p /data/xpam/core/data/media/replay/2026-10-22 && echo recording-on-b > /data/xpam/core/data/media/replay/2026-10-22/aa.cast'
check 'a recording made on B is copied to A and C (within ~1 min)' "wait_for \"on xaaa 'cat /data/xpam/core/data/media/replay/2026-10-22/aa.cast 2>/dev/null' | grep -q recording-on-b && on xaac 'cat /data/xpam/core/data/media/replay/2026-10-22/aa.cast 2>/dev/null' | grep -q recording-on-b\" 30"
check "each server's start marker stays its own (not copied)" "on xaab 'test -f /data/xpam/core/data/.xpam-prepared'"
check 'xpamctl ha status shows the topology and three members' "on xaaa 'cd /opt/xpam-installer && bash ./xpamctl.sh ha status' | grep -q 'active-active' && [[ \$(on xaaa 'cd /opt/xpam-installer && bash ./xpamctl.sh ha status' | grep -cE '^ +xpam-[abc] ') == 3 ]]"
check 'license-ids prints the same cluster ID on every server' "[[ \$(on xaaa 'cd /opt/xpam-installer && bash ./xpamctl.sh license-ids' | grep ^Cluster) == \$(on xaac 'cd /opt/xpam-installer && bash ./xpamctl.sh license-ids' | grep ^Cluster) ]]"

say "crash of the primary (A): B and C serve on"
docker exec -d xaab bash -c "rm -f /root/up.log; while true; do if curl -fsk --max-time 2 -o /dev/null https://$B/api/health/ || curl -fsk --max-time 2 -o /dev/null https://$C/api/health/; then echo \"\$(date +%s) up\"; else echo \"\$(date +%s) down\"; fi >> /root/up.log; sleep 1; done"
sleep 5
docker kill xaaa >/dev/null
start=$(date +%s)
wait_for "P=\$(primary_ip); [[ \$P == $B || \$P == $C ]]" 24
NEWP=$(primary_ip)
check "a new database primary by itself ($NEWP, $(( $(date +%s) - start ))s)" "[[ \$NEWP == $B || \$NEWP == $C ]]"
wait_for "[[ \$(sentinel_master xaab) == $B || \$(sentinel_master xaab) == $C ]]" 12
check "the Sentinels moved the main Redis ($(sentinel_master xaab))" "[[ \$(sentinel_master xaab) == $B || \$(sentinel_master xaab) == $C ]]"
check "XPAM on B writes again after the failover ($(( $(date +%s) - start ))s)" "wait_for \"django xaab 'from django.db import connection; c = connection.cursor(); c.execute(\\\"insert into xpam_ha_rehearsal values (%s)\\\", [\\\"after-crash\\\"]); print(\\\"WROTE\\\")' | grep -q WROTE\" 12"
sleep 3; docker exec xaab pkill -f 'up.log' >/dev/null 2>&1
OUTAGE=$(on xaab 'cat /root/up.log' | awk '$2=="down"{if(!s)s=$1; e=$1} $2=="up"&&s{d=e-s+1; if(d>m)m=d; s=0} END{if(s){d=e-s+1; if(d>m)m=d}; print m+0}')
check "users kept a server that answers (longest time with neither B nor C answering: ${OUTAGE}s, at most 60s)" "[[ $OUTAGE -le 60 ]]"
check 'no data was lost (seed and the write made through C)' "on $(node_of $NEWP) \"\$PSQL 'select v from xpam_ha_rehearsal order by 1'\" | tr '\n' ' ' | grep -q 'seed via-c'"

say "A comes back"
docker start xaaa >/dev/null
check 'A rejoins as a replica (never a second primary)' "wait_for \"on xaaa 'curl -s $CERTS https://$A:8008/patroni' 2>/dev/null | grep -q '\\\"role\\\": \\\"replica\\\"'\" 36"
check 'XPAM runs on A again' "wait_for 'core_healthy xaaa' 60"
check "A's Redis follows the main one" "wait_for \"[[ \\\$(sentinel_master xaaa) == $NEWP ]]\" 12"

say "rolling upgrade, active-active: the other servers wait with the new version until the database has it"
NEXT=v5.1.18
for n in $NODES; do
  on $n "for i in core gateway postgresql-ha; do docker tag xpam/\$i:$TAG xpam/\$i:$NEXT; done; sed -i 's/^export VERSION=.*/export VERSION=$NEXT/; s/^export XPAM_DEFAULT_VERSION=.*/export XPAM_DEFAULT_VERSION=$NEXT/' /opt/xpam-installer/static.env"
done
P=$(primary_ip); PN=$(node_of "$P")
STANDBYS=$(for n in $NODES; do [[ $n != "$PN" ]] && echo $n; done | xargs)
on $PN "cd /opt/xpam-installer && bash ./xpamctl.sh ha upgrade -y > /root/ha-upgrade-first.log 2>&1"
check 'ha upgrade on the primary first is refused' "on $PN 'grep -q \"Upgrade the other servers first\" /root/ha-upgrade-first.log' || { on $PN 'cat /root/ha-upgrade-first.log'; false; }"
docker exec -d $PN bash -c "rm -f /root/up.log; while true; do if curl -fsk --max-time 2 -o /dev/null https://$A/api/health/ || curl -fsk --max-time 2 -o /dev/null https://$B/api/health/ || curl -fsk --max-time 2 -o /dev/null https://$C/api/health/; then echo \"\$(date +%s) up\"; else echo \"\$(date +%s) down\"; fi >> /root/up.log; sleep 1; done"
FIRST=${STANDBYS%% *}
on $FIRST "cd /opt/xpam-installer && export $PASSENV && timeout 1800 bash ./xpamctl.sh ha upgrade -y > /root/ha-upgrade.log 2>&1"; tail -1 <(on $FIRST 'cat /root/ha-upgrade.log')
check "the upgraded server ($FIRST) waits: XPAM stopped there while the leader runs the old version" "wait_for \"! core_healthy $FIRST\" 12 && sleep 10 && ! on $FIRST 'docker ps --format {{.Names}}' | grep -qx xpam_core"
check 'the others serve on (the primary answers)' "answers $PN"
for n in ${STANDBYS#* }; do
  on $n "cd /opt/xpam-installer && export $PASSENV && timeout 1800 bash ./xpamctl.sh ha upgrade -y > /root/ha-upgrade.log 2>&1"; tail -1 <(on $n 'cat /root/ha-upgrade.log')
done
on $PN "cd /opt/xpam-installer && export $PASSENV && timeout 2400 bash ./xpamctl.sh ha upgrade -y > /root/ha-upgrade.log 2>&1"; tail -2 <(on $PN 'cat /root/ha-upgrade.log')
sleep 5; docker exec $PN pkill -f 'up.log' >/dev/null 2>&1
UOUT=$(on $PN 'cat /root/up.log' | awk '$2=="down"{if(!s)s=$1; e=$1} $2=="up"&&s{d=e-s+1; if(d>m)m=d; s=0} END{if(s){d=e-s+1; if(d>m)m=d}; print m+0}')
check "every server is on $NEXT" "for n in $NODES; do on \$n 'grep -qx CURRENT_VERSION=$NEXT /opt/xpam/config/config.txt' || exit 1; done"
check 'XPAM runs on all three again (new version)' "wait_for 'core_healthy xaaa && core_healthy xaab && core_healthy xaac' 60"
check "the rolling upgrade kept XPAM reachable (longest time with no server answering: ${UOUT}s, at most 120s)" "[[ $UOUT -le 120 ]]"
check 'all the data is there' "on \$(node_of \$(primary_ip)) \"\$PSQL 'select count(*) from xpam_ha_rehearsal'\" | grep -qx 3"

say "back to one server"
P=$(primary_ip); PN=$(node_of "$P")
for n in $NODES; do [[ $n == "$PN" ]] && continue; on $n 'cd /opt/xpam-installer && bash ./xpamctl.sh ha disable -y' | tail -1; done
on $PN 'cd /opt/xpam-installer && timeout 1200 bash ./xpamctl.sh ha disable -y > /root/ha-disable.log 2>&1'; tail -2 <(on $PN 'cat /root/ha-disable.log')
check "the last server ($PN) runs XPAM alone (no Patroni, no vote, no Sentinel)" "wait_for 'core_healthy $PN' 60 && on $PN 'docker ps --format {{.Image}}' | grep -q '^postgres:16' && ! on $PN 'docker ps --format {{.Names}}' | grep -qxE 'xpam_etcd|xpam_sentinel'"
check 'with all its data' "on $PN \"\$PSQL 'select count(*) from xpam_ha_rehearsal'\" | grep -qx 3"
check "the cluster's app certificate is gone from XPAM's containers" "! on $PN 'test -e /opt/xpam/config/certs/db_client.key'"

echo "RESULT: $PASS/$((PASS+FAIL)) passed"
[[ $FAIL -eq 0 ]]
