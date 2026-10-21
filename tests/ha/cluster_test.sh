#!/usr/bin/env bash
# XPAM high availability: the database layer on three simulated servers (A, B, witness) in containers.
# Converts an existing single-server database (as XPAM has it), then checks replication, failover when
# the primary crashes, the old primary rejoining (pg_rewind), a network split, a planned switchover, who
# can reach the database, the vote's permissions (the witness cannot change the records) and a rotation
# of every certificate while the database stays up.
#   tests/ha/cluster_test.sh [image-tag]      KEEP=1 keeps the containers
set -uo pipefail
TAG=${1:-v5.1.16}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK=$(mktemp -d); [[ "${KEEP:-}" == "1" ]] || trap 'cleanup; rm -rf "$WORK"' EXIT
NET=xhat; A=172.30.9.11; B=172.30.9.12; W=172.30.9.13
ETCD=gcr.io/etcd-development/etcd:v3.5.21
PASS=0; FAIL=0
check() { if eval "$2"; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }
r() { head -c 64 /dev/urandom | tr -dc A-Za-z0-9 | head -c "${1:-32}"; }
cleanup() {
  docker rm -f hat-a hat-b hat-a-etcd hat-b-etcd hat-w-etcd hat-a-ns hat-b-ns hat-w-ns hat-seed hat-stranger >/dev/null 2>&1
  docker volume rm hat-a-data hat-b-data hat-a-etcd hat-b-etcd hat-w-etcd >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
}
cleanup
umask 077
# one certificate folder per simulated server (as on real machines): A and B get the node certificate,
# the witness its own
bash "$HERE/../../ha/certs.sh" "$WORK/ca" $A $B $W
for n in a b; do mkdir -p "$WORK/certs-$n"; cp "$WORK/ca/ca.crt" "$WORK/ca/node.crt" "$WORK/ca/node.key" "$WORK/ca/client.crt" "$WORK/ca/client.key" "$WORK/certs-$n/"; done
mkdir -p "$WORK/certs-w"; cp "$WORK/ca/ca.crt" "$WORK/certs-w/"; cp "$WORK/ca/witness.crt" "$WORK/certs-w/node.crt"; cp "$WORK/ca/witness.key" "$WORK/certs-w/node.key"
chmod 755 "$WORK"/certs-*; chmod 644 "$WORK"/certs-*/*  # (bind-mounted into containers; the test only)
# DOCKER_SUBNET stands for XPAM's internal container network (not the servers' network)
printf 'DB_USER=xpam\nDB_PASSWORD=%s\nDB_NAME=xpam\nHA_REPL_PASSWORD=%s\nHA_PATRONI_PASSWORD=%s\nHA_REWIND_PASSWORD=%s\nHA_ETCD_PASSWORD=%s\nHA_WITNESS_IP=%s\nDOCKER_SUBNET=10.99.0.0/24\n' \
  "$(r 24)" "$(r 24)" "$(r 24)" "$(r 24)" "$(r 24)" "$W" > "$WORK/env"
ROOTPW=$(r 24)
. "$WORK/env"
docker network create --subnet 172.30.9.0/24 "$NET" >/dev/null
docker volume create hat-a-data >/dev/null; docker volume create hat-b-data >/dev/null

# the existing single-server database, plus the two accounts 'xpamctl ha init' creates
docker run -d --name hat-seed -v hat-a-data:/var/lib/postgresql/data -e POSTGRES_USER=xpam \
  -e POSTGRES_PASSWORD="$DB_PASSWORD" -e POSTGRES_DB=xpam postgres:16.15-bookworm >/dev/null
for _ in $(seq 60); do docker exec hat-seed psql -U xpam -d xpam -qc 'select 1' >/dev/null 2>&1 && break; sleep 1; done
sleep 2
docker exec hat-seed psql -U xpam -d xpam -qc "CREATE TABLE t(v text); INSERT INTO t VALUES ('before-ha');"
docker exec -e RP="$HA_REPL_PASSWORD" -e WP="$HA_REWIND_PASSWORD" hat-seed sh -c '
  psql -U xpam -d xpam -q -v rp="$RP" -v wp="$WP" <<SQL
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD :'"'"'rp'"'"';
CREATE ROLE xpam_rewind WITH LOGIN PASSWORD :'"'"'wp'"'"';
GRANT EXECUTE ON FUNCTION pg_catalog.pg_ls_dir(text, boolean, boolean) TO xpam_rewind;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_stat_file(text, boolean) TO xpam_rewind;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text) TO xpam_rewind;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean) TO xpam_rewind;
SQL'
docker rm -f hat-seed >/dev/null

ns_run() { # node ip: a small container that holds the simulated server's address (its network)
  docker run -d --name "hat-$1-ns" --network "$NET" --ip "$2" --entrypoint sleep "xpam/postgresql-ha:$TAG" infinity >/dev/null
}
etcd_run() { # member-name ip node initial-cluster state
  docker run -d --name "hat-$3-etcd" --network "container:hat-$3-ns" -v "$WORK/certs-$3:/certs:ro" -v "hat-$3-etcd:/etcd-data" "$ETCD" \
    /usr/local/bin/etcd --name "$1" --data-dir /etcd-data --listen-peer-urls https://0.0.0.0:2380 \
    --listen-client-urls https://0.0.0.0:2379 --advertise-client-urls "https://$2:2379" \
    --initial-advertise-peer-urls "https://$2:2380" --initial-cluster "$4" \
    --initial-cluster-token xpam-ha --initial-cluster-state "$5" --client-cert-auth --trusted-ca-file /certs/ca.crt \
    --cert-file /certs/node.crt --key-file /certs/node.key --peer-client-cert-auth --peer-trusted-ca-file /certs/ca.crt \
    --peer-cert-file /certs/node.crt --peer-key-file /certs/node.key --heartbeat-interval 250 --election-timeout 2500 >/dev/null
}
pg_run() { # a|b ip peer
  docker run -d --name "hat-$1" --network "container:hat-$1-ns" --env-file "$WORK/env" \
    -e HA_NODE_NAME="xpam-$1" -e HA_NODE_IP="$2" -e HA_PEER_IP="$3" \
    -v "hat-$1-data:/var/lib/postgresql/data" -v "$WORK/certs-$1:/etc/xpam-ha:ro" "xpam/postgresql-ha:$TAG" >/dev/null
}
PC="--cacert /run/xpam-ha/ca.crt --cert /run/xpam-ha/node.crt --key /run/xpam-ha/node.key"
role() { docker exec "hat-$1" sh -c "curl -s -o /dev/null -w '%{http_code}' $PC https://127.0.0.1:8008/primary" 2>/dev/null; }
sql() { docker exec "hat-$1" psql -U xpam -d xpam -Atqc "$2" 2>/dev/null; }
wait_for() { for _ in $(seq "${2:-60}"); do eval "$1" && return 0; sleep 2; done; return 1; }
members() { docker exec "hat-$1" sh -c "curl -s $PC https://127.0.0.1:8008/cluster" 2>/dev/null; }
ectl() { # node etcdctl-args... (with that machine's certificate)
  local n=$1; shift
  docker exec "hat-$n-etcd" etcdctl --endpoints https://127.0.0.1:2379 --cacert /certs/ca.crt --cert /certs/node.crt --key /certs/node.key "$@"
}
reload_node() { # a|b: new certificates in place without restarting PostgreSQL (as 'xpamctl ha' does)
  docker restart "hat-$1-etcd" >/dev/null
  docker exec "hat-$1" xpam-reload-certs >/dev/null
}

# ---- setup as 'xpamctl ha init': the vote starts with A and the witness
AW="xpam-a=https://$A:2380,xpam-witness=https://$W:2380"
ns_run a $A; ns_run b $B; ns_run w $W
etcd_run xpam-a $A a "$AW" new; etcd_run xpam-witness $W w "$AW" new
wait_for 'ectl a endpoint health >/dev/null 2>&1' 30
# the vote's permissions, before PostgreSQL starts: XPAM's records only for the account xpam-node
ectl a user add root --new-user-password="$ROOTPW" >/dev/null && ectl a user grant-role root root >/dev/null &&
ectl a role add xpam >/dev/null && ectl a role grant-permission xpam --prefix=true readwrite /xpam/ >/dev/null &&
ectl a user add xpam-node --new-user-password="$HA_ETCD_PASSWORD" >/dev/null && ectl a user grant-role xpam-node xpam >/dev/null &&
ectl a auth enable >/dev/null
check 'the vote checks permissions (auth enabled)' "wait_for \"ectl a --user root:$ROOTPW auth status 2>/dev/null | grep -q 'Authentication Status: true'\" 15"
pg_run a $A $B
wait_for '[[ $(role a) == 200 ]]' 60
check 'the converted server becomes the primary and keeps its data' '[[ $(role a) == 200 && $(sql a "select v from t") == before-ha ]]'
check 'Patroni works through its own account in the vote' 'sql a "insert into t values (\$\$under-rbac\$\$)"'
check "the witness's certificate cannot change XPAM's records" "! ectl w put /xpam/xpam/leader xpam-witness >/dev/null 2>&1"
check "nor read them" "! ectl w get --prefix /xpam/ --keys-only >/dev/null 2>&1"
check "the account xpam-node can (control)" "wait_for \"ectl a --user xpam-node:$HA_ETCD_PASSWORD get --prefix /xpam/xpam/ --keys-only 2>/dev/null | grep -q /xpam/xpam/leader\" 15"
check "the leader record still names A (the witness changed nothing)" "[[ \$(role a) == 200 ]]"

# ---- the second server joins (as 'xpamctl ha join': added to the vote by the administrator account)
ectl a --user "root:$ROOTPW" member add xpam-b --peer-urls "https://$B:2380" >/dev/null
etcd_run xpam-b $B b "$AW,xpam-b=https://$B:2380" existing
pg_run b $B $A
wait_for 'members a | grep -q "\"streaming\""' 90
check 'the second server copies the database and streams changes' 'members a | grep -q "\"streaming\""'
wait_for 'members a | grep -q "sync_standby"' 30
check 'replication is synchronous (no committed transaction lost on failover)' 'members a | grep -q "sync_standby"'
sql a "INSERT INTO t VALUES ('written-on-a')"
wait_for '[[ $(sql b "select count(*) from t") == 3 ]]' 15
check 'a change on the primary is on the standby' '[[ $(sql b "select count(*) from t") == 3 ]]'
check 'the standby is read-only' '! docker exec hat-b psql -U xpam -d xpam -qc "insert into t values (1)" >/dev/null 2>&1'

# ---- the primary crashes (the whole machine)
docker kill hat-a hat-a-etcd hat-a-ns >/dev/null
start=$(date +%s)
wait_for '[[ $(role b) == 200 ]]' 60
check "the standby takes over by itself ($(( $(date +%s) - start ))s)" '[[ $(role b) == 200 ]]'
check 'the new primary has all committed data and accepts writes' \
  '[[ $(sql b "select count(*) from t") == 3 ]] && sql b "insert into t values ('"'"'written-on-b'"'"')"; [[ $(sql b "select count(*) from t") == 4 ]]'
docker start hat-a-ns >/dev/null; docker start hat-a-etcd >/dev/null; sleep 1; docker start hat-a >/dev/null
wait_for 'members b | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if any(m[\"name\"]==\"xpam-a\" and m[\"state\"]==\"streaming\" for m in d[\"members\"]) else 1)"' 90
check 'the old primary rejoins as a standby (pg_rewind with the limited account)' '[[ $(role a) != 200 ]] && members b | grep -q "\"streaming\""'
wait_for '[[ $(sql a "select count(*) from t") == 4 ]]' 20
check 'and receives what was written meanwhile' '[[ $(sql a "select count(*) from t") == 4 ]]'

# ---- network split
wait_for 'members b | grep -q "sync_standby"' 60
docker network disconnect "$NET" hat-b-ns
wait_for '[[ $(role a) == 200 ]]' 60
check 'split: the other server (with the witness) takes over' '[[ $(role a) == 200 ]]'
wait_for '[[ $(role b) != 200 ]]' 45
check 'split: the cut-off server stops being primary (no split brain)' '[[ $(role b) != 200 ]]'
docker network connect --ip $B "$NET" hat-b-ns
sql a "INSERT INTO t VALUES ('after-split')"
wait_for '[[ $(sql b "select count(*) from t") == 5 ]]' 90
check 'after the split heals, the cut-off server follows the new primary' '[[ $(sql b "select count(*) from t") == 5 && $(role b) != 200 ]]'

# ---- planned switchover and the API password
wait_for 'members a | grep -q "sync_standby"' 60
code=$(docker exec -e P="$HA_PATRONI_PASSWORD" hat-a sh -c "curl -s -o /dev/null -w '%{http_code}' $PC -u \"patroni:\$P\" -XPOST \
  -H 'Content-Type: application/json' -d '{\"leader\":\"xpam-a\",\"candidate\":\"xpam-b\"}' https://127.0.0.1:8008/switchover")
wait_for '[[ $(role b) == 200 ]]' 60
check "planned switchover moves the primary to the other server (HTTP $code)" '[[ $(role b) == 200 && $(role a) != 200 ]]'
code=$(docker exec hat-a sh -c "curl -s -o /dev/null -w '%{http_code}' $PC -XPOST -H 'Content-Type: application/json' \
  -d '{\"leader\":\"xpam-b\",\"candidate\":\"xpam-a\"}' https://127.0.0.1:8008/switchover")
check "switchover without the API password is refused (HTTP $code)" '[[ $code == 401 ]]'

# ---- nobody else reaches the database
docker run -d --name hat-stranger --network "$NET" --ip 172.30.9.50 --entrypoint sleep "xpam/postgresql-ha:$TAG" infinity >/dev/null
try_sql() { docker exec -e PGCONNECT_TIMEOUT=5 "$1" psql "$2" -Atqc 'select 1' >/dev/null 2>&1; }
TLSC="sslmode=verify-ca sslrootcert=/run/xpam-ha/ca.crt sslcert=/run/xpam-ha/node.crt sslkey=/run/xpam-ha/node.key"
check 'a stranger cannot log in as XPAM (even with the password)' "! try_sql hat-stranger 'host=$B user=xpam password=$DB_PASSWORD dbname=xpam sslmode=require'"
check 'the other server cannot log in as XPAM (only replication)' "! try_sql hat-a 'host=$B user=xpam password=$DB_PASSWORD dbname=xpam sslmode=require'"
check 'replication without the cluster certificate is refused' "! docker exec -e PGCONNECT_TIMEOUT=5 hat-a psql 'host=$B user=replicator password=$HA_REPL_PASSWORD replication=true sslmode=require' -c IDENTIFY_SYSTEM >/dev/null 2>&1"
check 'replication with password and certificate works' "docker exec -e PGCONNECT_TIMEOUT=5 hat-a psql 'host=$B user=replicator password=$HA_REPL_PASSWORD replication=true $TLSC' -c IDENTIFY_SYSTEM >/dev/null 2>&1"
check 'the rewind account cannot read XPAM data' "! docker exec -e PGCONNECT_TIMEOUT=5 hat-a psql 'host=$B user=xpam_rewind password=$HA_REWIND_PASSWORD dbname=postgres $TLSC' -Atqc 'select count(*) from pg_authid' >/dev/null 2>&1"
check 'the cluster API refuses callers without the certificate' \
  "[[ \$(docker exec hat-stranger sh -c \"curl -sk -o /dev/null -w '%{http_code}' --max-time 5 https://$B:8008/cluster\" 2>/dev/null) == 000 ]]"

# ---- rotation of every certificate (new CA) while the database stays up, as 'xpamctl ha rotate-certs'
wait_for 'members b | grep -q "sync_standby"' 60
mkdir -p "$WORK/old"; cp "$WORK/certs-a/"* "$WORK/old/"
bash "$HERE/../../ha/certs.sh" "$WORK/ca2" $A $B $W
pause() { docker exec -e P="$HA_PATRONI_PASSWORD" "hat-$1" sh -c "curl -s -o /dev/null -w '%{http_code}' $PC -u \"patroni:\$P\" -XPATCH -H 'Content-Type: application/json' -d '{\"pause\": $2}' https://127.0.0.1:8008/config"; }
check 'maintenance mode on for the rotation' '[[ $(pause b true) == 200 ]]'
started=$(docker inspect -f '{{.State.StartedAt}}' hat-b)
for n in b a; do cp "$WORK/ca2/ca.crt" "$WORK/ca2/node.crt" "$WORK/ca2/node.key" "$WORK/ca2/client.crt" "$WORK/ca2/client.key" "$WORK/certs-$n/"; done
cp "$WORK/ca2/ca.crt" "$WORK/certs-w/"; cp "$WORK/ca2/witness.crt" "$WORK/certs-w/node.crt"; cp "$WORK/ca2/witness.key" "$WORK/certs-w/node.key"
chmod 644 "$WORK"/certs-*/*
reload_node b; docker restart hat-w-etcd >/dev/null; reload_node a
sleep 10
check 'the primary kept running during the rotation (not restarted)' "[[ \$(docker inspect -f '{{.State.StartedAt}}' hat-b) == '$started' ]] && sql b 'insert into t values (\$\$during-rotation\$\$)'"
check 'the vote works again with the new certificates' "wait_for \"ectl a --user root:$ROOTPW endpoint health --cluster 2>&1 | grep -c 'is healthy' | grep -qx 3\" 30"
check 'maintenance mode off' '[[ $(pause b null) == 200 ]]'
wait_for '[[ $(sql a "select count(*) from t") == 6 ]]' 60
check 'replication resumes with the new certificates' '[[ $(sql a "select count(*) from t") == 6 ]] && wait_for "members b | grep -q sync_standby" 30'
docker cp "$WORK/old/." hat-stranger:/tmp/old >/dev/null
check 'the old certificate is no longer accepted' \
  "[[ \$(docker exec hat-stranger sh -c \"curl -s -o /dev/null -w '%{http_code}' --max-time 5 --cacert /tmp/old/ca.crt --cert /tmp/old/node.crt --key /tmp/old/node.key https://$B:8008/cluster\" 2>/dev/null) == 000 ]]"

echo "RESULT: $PASS/$((PASS+FAIL)) passed"
[[ $FAIL -eq 0 ]]
