#!/usr/bin/env bash
# XPAM high availability: the database layer on three simulated servers (A, B, witness) in containers.
# Converts an existing single-server database (as XPAM has it), then checks replication, failover when
# the primary crashes, the old primary rejoining (pg_rewind), a network split, and a planned switchover.
#   tests/ha/cluster_test.sh [image-tag]
set -uo pipefail
TAG=${1:-v5.1.15}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK=$(mktemp -d); [[ "${KEEP:-}" == "1" ]] || trap 'cleanup; rm -rf "$WORK"' EXIT
NET=xhat; A=172.30.9.11; B=172.30.9.12; W=172.30.9.13
PASS=0; FAIL=0
check() { if eval "$2"; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }
r() { head -c 64 /dev/urandom | tr -dc A-Za-z0-9 | head -c "${1:-32}"; }
cleanup() {
  docker rm -f hat-a hat-b hat-a-etcd hat-b-etcd hat-w-etcd hat-seed hat-stranger >/dev/null 2>&1
  docker volume rm hat-a-data hat-b-data >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
}
cleanup
umask 077
bash "$HERE/../../ha/certs.sh" "$WORK/certs" $A $B $W
# DOCKER_SUBNET stands for XPAM's internal container network (not the servers' network): XPAM's own
# account must be refused from the other server
printf 'DB_USER=xpam\nDB_PASSWORD=%s\nDB_NAME=xpam\nHA_REPL_PASSWORD=%s\nHA_PATRONI_PASSWORD=%s\nHA_REWIND_PASSWORD=%s\nHA_WITNESS_IP=%s\nDOCKER_SUBNET=10.99.0.0/24\n' \
  "$(r 24)" "$(r 24)" "$(r 24)" "$(r 24)" "$W" > "$WORK/env"
. "$WORK/env"
docker network create --subnet 172.30.9.0/24 "$NET" >/dev/null
docker volume create hat-a-data >/dev/null; docker volume create hat-b-data >/dev/null

# the existing single-server database (with data), plus the replication user `xpamctl ha init` creates
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

etcd_run() { # member-name ip node initial-cluster state: the etcd container owns the simulated server's network
  docker run -d --name "hat-$3-etcd" --network "$NET" --ip "$2" -v "$WORK/certs:/certs:ro" gcr.io/etcd-development/etcd:v3.5.21 \
    /usr/local/bin/etcd --name "$1" --data-dir /etcd-data --listen-peer-urls https://0.0.0.0:2380 \
    --listen-client-urls https://0.0.0.0:2379 --advertise-client-urls "https://$2:2379" \
    --initial-advertise-peer-urls "https://$2:2380" --initial-cluster "$4" \
    --initial-cluster-token xpam-ha --initial-cluster-state "$5" --client-cert-auth --trusted-ca-file /certs/ca.crt \
    --cert-file /certs/node.crt --key-file /certs/node.key --peer-client-cert-auth --peer-trusted-ca-file /certs/ca.crt \
    --peer-cert-file /certs/node.crt --peer-key-file /certs/node.key --heartbeat-interval 250 --election-timeout 2500 >/dev/null
}
pg_run() { # a|b ip peer (shares the network of the server's etcd container)
  docker run -d --name "hat-$1" --network "container:hat-$1-etcd" --env-file "$WORK/env" \
    -e HA_NODE_NAME="xpam-$1" -e HA_NODE_IP="$2" -e HA_PEER_IP="$3" \
    -v "hat-$1-data:/var/lib/postgresql/data" -v "$WORK/certs:/etc/xpam-ha:ro" "xpam/postgresql-ha:$TAG" >/dev/null
}
PC="--cacert /run/xpam-ha/ca.crt --cert /run/xpam-ha/node.crt --key /run/xpam-ha/node.key"
role() { docker exec "hat-$1" sh -c "curl -s -o /dev/null -w '%{http_code}' $PC https://127.0.0.1:8008/primary" 2>/dev/null; }
sql() { docker exec "hat-$1" psql -U xpam -d xpam -Atqc "$2" 2>/dev/null; }
wait_for() { for _ in $(seq "${2:-60}"); do eval "$1" && return 0; sleep 2; done; return 1; }
members() { docker exec "hat-$1" sh -c "curl -s $PC https://127.0.0.1:8008/cluster" 2>/dev/null; }

# as 'xpamctl ha init' does: the vote starts with the first server and the witness
AW="xpam-a=https://$A:2380,xpam-witness=https://$W:2380"
etcd_run xpam-a $A a "$AW" new; etcd_run xpam-witness $W w "$AW" new
pg_run a $A $B
wait_for '[[ $(role a) == 200 ]]' 60
check 'the converted server becomes the primary and keeps its data' '[[ $(role a) == 200 && $(sql a "select v from t") == before-ha ]]'

# server B joins (empty): it copies the primary
# as 'xpamctl ha join' does: the second server is added to the vote, then starts
docker exec hat-a-etcd etcdctl --endpoints https://127.0.0.1:2379 --cacert /certs/ca.crt --cert /certs/node.crt \
  --key /certs/node.key member add xpam-b --peer-urls "https://$B:2380" >/dev/null
etcd_run xpam-b $B b "$AW,xpam-b=https://$B:2380" existing
pg_run b $B $A
wait_for 'members a | grep -q "\"streaming\""' 90
check 'the second server copies the database and streams changes' 'members a | grep -q "\"streaming\""'
wait_for 'members a | grep -q "sync_standby"' 30
check 'replication is synchronous (no committed transaction lost on failover)' 'members a | grep -q "sync_standby"'
sql a "INSERT INTO t VALUES ('written-on-a')"
wait_for '[[ $(sql b "select count(*) from t") == 2 ]]' 15
check 'a change on the primary is on the standby' '[[ $(sql b "select count(*) from t") == 2 ]]'
check 'the standby is read-only' '! docker exec hat-b psql -U xpam -d xpam -qc "insert into t values (1)" >/dev/null 2>&1'

# the primary crashes: the standby takes over by itself
docker kill hat-a hat-a-etcd >/dev/null
start=$(date +%s)
wait_for '[[ $(role b) == 200 ]]' 60
took=$(( $(date +%s) - start ))
check "the standby takes over by itself (${took}s)" '[[ $(role b) == 200 ]]'
check 'the new primary has all committed data and accepts writes' \
  '[[ $(sql b "select count(*) from t") == 2 ]] && sql b "insert into t values ('"'"'written-on-b'"'"')"; [[ $(sql b "select count(*) from t") == 3 ]]'

# the old primary comes back: it rejoins as standby (never a second primary)
docker start hat-a-etcd >/dev/null; sleep 1; docker start hat-a >/dev/null
wait_for 'members b | python3 -c "import json,sys; d=json.load(sys.stdin); exit(0 if any(m[\"name\"]==\"xpam-a\" and m[\"state\"]==\"streaming\" for m in d[\"members\"]) else 1)"' 90
check 'the old primary rejoins as a standby' '[[ $(role a) != 200 ]] && members b | grep -q "\"streaming\""'
wait_for '[[ $(sql a "select count(*) from t") == 3 ]]' 20
check 'and receives what was written meanwhile' '[[ $(sql a "select count(*) from t") == 3 ]]'

# network split: the primary (B) loses both other servers; it must stop being primary, A takes over.
# (Patroni promotes only a standby confirmed synchronous: right after a rejoin there is a short window
# without automatic failover, by design — no committed transaction is ever lost.)
wait_for 'members b | grep -q "sync_standby"' 60
check 'the rejoined server becomes the synchronous standby again' 'members b | grep -q "sync_standby"'
docker network disconnect "$NET" hat-b-etcd
wait_for '[[ $(role a) == 200 ]]' 60
check 'split: the other server (with the witness) takes over' '[[ $(role a) == 200 ]]'
wait_for '[[ $(role b) != 200 ]]' 45
check 'split: the cut-off server stops being primary (no split brain)' '[[ $(role b) != 200 ]]'
docker network connect --ip $B "$NET" hat-b-etcd
sql a "INSERT INTO t VALUES ('after-split')"
wait_for '[[ $(sql b "select count(*) from t") == 4 ]]' 90
check 'after the split heals, the cut-off server follows the new primary' '[[ $(sql b "select count(*) from t") == 4 && $(role b) != 200 ]]'

# planned switchover (maintenance): back to B through Patroni's REST API (to a synchronous standby)
wait_for 'members a | grep -q "sync_standby"' 60
code=$(docker exec -e P="$HA_PATRONI_PASSWORD" hat-a sh -c "curl -s -o /dev/null -w '%{http_code}' $PC -u \"patroni:\$P\" -XPOST \
  -H 'Content-Type: application/json' -d '{\"leader\":\"xpam-a\",\"candidate\":\"xpam-b\"}' https://127.0.0.1:8008/switchover")
wait_for '[[ $(role b) == 200 ]]' 60
check "planned switchover moves the primary to the other server (HTTP $code)" '[[ $(role b) == 200 && $(role a) != 200 ]]'
code=$(docker exec hat-a sh -c "curl -s -o /dev/null -w '%{http_code}' $PC -XPOST -H 'Content-Type: application/json' \
  -d '{\"leader\":\"xpam-b\",\"candidate\":\"xpam-a\"}' https://127.0.0.1:8008/switchover")
check "switchover without the REST password is refused (HTTP $code)" '[[ $code == 401 ]]'

# ---- nobody else reaches the database
docker run -d --name hat-stranger --network "$NET" --ip 172.30.9.50 --entrypoint sleep "xpam/postgresql-ha:$TAG" infinity >/dev/null
try_sql() { # container conninfo -> exit code of a login
  docker exec -e PGCONNECT_TIMEOUT=5 "$1" psql "$2" -Atqc 'select 1' >/dev/null 2>&1
}
check 'a stranger cannot log in as XPAM (even with the password)' "! try_sql hat-stranger 'host=$B user=xpam password=$DB_PASSWORD dbname=xpam sslmode=require'"
check 'the other server cannot log in as XPAM (only replication)' "! try_sql hat-a 'host=$B user=xpam password=$DB_PASSWORD dbname=xpam sslmode=require'"
check 'replication without the cluster certificate is refused' "! docker exec -e PGCONNECT_TIMEOUT=5 hat-a psql 'host=$B user=replicator password=$HA_REPL_PASSWORD replication=true sslmode=require' -c IDENTIFY_SYSTEM >/dev/null 2>&1"
check 'replication with password and certificate works' "docker exec -e PGCONNECT_TIMEOUT=5 hat-a psql 'host=$B user=replicator password=$HA_REPL_PASSWORD replication=true sslmode=verify-ca sslrootcert=/run/xpam-ha/ca.crt sslcert=/run/xpam-ha/node.crt sslkey=/run/xpam-ha/node.key' -c IDENTIFY_SYSTEM >/dev/null 2>&1"
check 'the rewind account cannot read XPAM data' "! docker exec -e PGCONNECT_TIMEOUT=5 hat-a psql 'host=$B user=xpam_rewind password=$HA_REWIND_PASSWORD dbname=postgres sslmode=verify-ca sslrootcert=/run/xpam-ha/ca.crt sslcert=/run/xpam-ha/node.crt sslkey=/run/xpam-ha/node.key' -Atqc 'select count(*) from pg_authid' >/dev/null 2>&1"
check "the cluster API refuses callers without the certificate (HTTP $(docker exec hat-stranger sh -c "curl -sk -o /dev/null -w '%{http_code}' --max-time 5 https://$B:8008/cluster" 2>/dev/null))" \
  "[[ \$(docker exec hat-stranger sh -c \"curl -sk -o /dev/null -w '%{http_code}' --max-time 5 https://$B:8008/cluster\" 2>/dev/null) == 000 ]]"

echo "RESULT: $PASS/$((PASS+FAIL)) passed"
[[ $FAIL -eq 0 ]]
