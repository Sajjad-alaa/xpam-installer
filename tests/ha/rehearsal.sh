#!/usr/bin/env bash
# XPAM high availability rehearsal: the real `xpamctl ha` flow on three simulated servers (privileged
# Rocky Linux containers with their own Docker, memory-capped). A and B get a reduced XPAM install (core
# and gateway only, SERVER_SIZE=small); W is the witness (Docker only).
#   tests/ha/rehearsal.sh [tag]          (images xpam/core, xpam/gateway, xpam/postgresql-ha:<tag> local)
# Checks: init, witness, join, replication, file copy, firewall, crash of A -> B takes over with XPAM,
# A rejoins as standby, planned switchover back to A.
set -uo pipefail
TAG=${1:-v5.1.15}
NET=xhar; A=172.31.9.11; B=172.31.9.12; W=172.31.9.13
PASS=0; FAIL=0
check() { if eval "$2"; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }
on() { local n=$1; shift; docker exec "$n" bash -lc "$*"; }
wait_for() { for _ in $(seq "${2:-60}"); do eval "$1" && return 0; sleep 5; done; return 1; }
say() { echo "== $(date +%T) $*"; }
cleanup() {
  docker rm -f hara harb harw >/dev/null 2>&1
  docker volume rm hara-docker harb-docker harw-docker >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1
}
[[ "${KEEP:-}" == "1" ]] || trap cleanup EXIT
cleanup
export XPAM_HA_BUNDLE_PASSPHRASE="Bundle-$(head -c 32 /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)"
export XPAM_HA_PASSPHRASE="Cluster-$(head -c 32 /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)"
PASSENV="XPAM_HA_BUNDLE_PASSPHRASE=$XPAM_HA_BUNDLE_PASSPHRASE XPAM_HA_PASSPHRASE=$XPAM_HA_PASSPHRASE"
MIN="KOKO_ENABLED=0 CHEN_ENABLED=0 KAEL_ENABLED=0 BROWSER_ENABLED=0 WORKSPACE_ENABLED=0 WEB_ENABLED=0 WORKER_ENABLED=0 SERVER_SIZE=small XPAM_IMAGE_REGISTRY=local"

say "servers"
docker network create --subnet 172.31.9.0/24 "$NET" >/dev/null
node() { # name ip memory
  docker run -d --privileged --name "$1" --hostname "$1" --memory "$3" --memory-swap "$3" --cpus 2 \
    --network "$NET" --ip "$2" -v "$1-docker:/var/lib/docker" -v /opt/xpam-installer:/src:ro \
    rockylinux/rockylinux:9-ubi-init >/dev/null
}
node hara $A 1500m; node harb $B 1500m; node harw $W 400m
sleep 8
for n in hara harb harw; do
  on $n 'for i in $(seq 20); do dnf -y -q install git tar rsync openssh-server openssh-clients iptables-nft procps-ng iproute python3 openssl >/dev/null 2>&1 && rpm -q git rsync openssh-server >/dev/null && break; sleep 10; done; systemctl enable --now sshd >/dev/null 2>&1; git config --global --add safe.directory "*"' &
done; wait
check 'the simulated servers have their packages' "on hara 'rpm -q git rsync' >/dev/null && on harb 'rpm -q git rsync' >/dev/null && on harw 'rpm -q rsync' >/dev/null"

say "XPAM on A and B (reduced: core + gateway)"
install() { # node
  on "$1" "cd /root && export $MIN XPAM_INSTALLER_REPO=/src AUTO_INSTALL=1 XPAM_IMAGE_REGISTRY=local XPAM_SKIP_SELF_UPDATE=1; timeout 1200 bash /src/quick_start.sh > /root/install1.log 2>&1" || true
  docker save "xpam/core:$TAG" "xpam/gateway:$TAG" "xpam/postgresql-ha:$TAG" postgres:16.15-bookworm redis:7.4.10-bookworm \
    gcr.io/etcd-development/etcd:v3.5.21 | docker exec -i "$1" docker load -q >/dev/null
  # the reduced setup goes into config.txt before XPAM starts (the containers read it, not the shell)
  on "$1" "for kv in $MIN; do echo \$kv >> /opt/xpam/config/config.txt; done; cd /opt/xpam-installer && export $MIN AUTO_INSTALL=1 XPAM_IMAGE_REGISTRY=local XPAM_SKIP_SELF_UPDATE=1; timeout 1800 bash ./xpamctl.sh install > /root/install2.log 2>&1"
}
install hara & install harb & wait
check 'XPAM installed and running on A' "on hara 'docker ps --format {{.Names}}' | grep -qx xpam_core"
check 'XPAM installed and running on B' "on harb 'docker ps --format {{.Names}}' | grep -qx xpam_core"

say "seed data on A (a setting and a recording file)"
PSQL='docker exec xpam_postgresql psql -U $(grep ^DB_USER= /opt/xpam/config/config.txt | cut -d= -f2) -d $(grep ^DB_NAME= /opt/xpam/config/config.txt | cut -d= -f2) -Atqc'
on hara "$PSQL 'CREATE TABLE xpam_ha_rehearsal(v text); INSERT INTO xpam_ha_rehearsal VALUES (\$\$seed\$\$)'"
on hara 'mkdir -p /data/xpam/core/data/replay/2026-10-21 && echo recording > /data/xpam/core/data/replay/2026-10-21/rehearsal.cast'

say "ha init on A (waits for the witness)"
on hara "cd /opt/xpam-installer && export $PASSENV && nohup bash ./xpamctl.sh ha init $A $B $W -y > /root/ha-init.log 2>&1 &"
wait_for "on hara 'test -s /opt/xpam/config/ha/xpam-ha-witness.enc'" 60
check 'init prepared the witness and join bundles' "on hara 'test -s /opt/xpam/config/ha/xpam-ha-join.enc'"
check 'the bundles are encrypted (not readable without the passphrase)' "! on hara 'gzip -t /opt/xpam/config/ha/xpam-ha-join.enc' 2>/dev/null && ! on hara 'grep -qa SECRET_KEY /opt/xpam/config/ha/xpam-ha-join.enc'"
check 'the CA key is stored only encrypted' "on hara 'test -s /opt/xpam/config/ha/certs/ca.key.enc && ! test -e /opt/xpam/config/ha/certs/ca.key'"
check 'the witness bundle holds no XPAM secrets' "! on hara \"export $PASSENV; openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass env:XPAM_HA_BUNDLE_PASSPHRASE -in /opt/xpam/config/ha/xpam-ha-witness.enc 2>/dev/null | tar xzO 2>/dev/null\" | grep -qE 'SECRET_KEY|PASSWORD|PRIVATE KEY.*ca'"

say "witness"
# the witness: Docker CE only (classic storage driver: the simulated server's own disk is an overlay)
on harw 'dnf -y -q install dnf-plugins-core >/dev/null 2>&1; dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo >/dev/null 2>&1; dnf -y -q install docker-ce docker-ce-cli containerd.io >/dev/null 2>&1; mkdir -p /etc/docker; echo "{\"features\":{\"containerd-snapshotter\":false}}" > /etc/docker/daemon.json; systemctl enable --now docker >/dev/null 2>&1; docker version --format "{{.Server.Version}}"' | tail -1
docker save gcr.io/etcd-development/etcd:v3.5.21 | docker exec -i harw docker load -q >/dev/null
docker exec hara cat /opt/xpam/config/ha/xpam-ha-witness.enc | docker exec -i -e XPAM_HA_BUNDLE_PASSPHRASE harw sh -c 'mkdir -p /root/w && openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass env:XPAM_HA_BUNDLE_PASSPHRASE | tar xzf - -C /root/w'
on harw '/root/w/witness.sh' | tail -1
wait_for "on hara 'grep -q \"This server is the primary\" /root/ha-init.log'" 120
check 'A is the primary after init' "[[ \$(on hara 'curl -s -o /dev/null -w %{http_code} --cacert /opt/xpam/config/ha/certs/ca.crt --cert /opt/xpam/config/ha/certs/node.crt --key /opt/xpam/config/ha/certs/node.key https://$A:8008/primary') == 200 ]]"
check 'XPAM runs on A under high availability' "wait_for \"on hara 'docker ps --format \\\"{{.Names}} {{.Status}}\\\"' | grep -q '^xpam_core .*(healthy)'\" 60"
check 'the seeded data survived the switch to Patroni' "on hara \"\$PSQL 'select v from xpam_ha_rehearsal'\" | grep -qx seed"
check 'the agent runs on A' "on hara 'systemctl is-active xpam-ha' | grep -qx active"
check 'the cluster ports accept only the other server (and the vote the witness)' "on hara 'iptables -S XPAM-HA' | grep -q \"$B.*5432\" && on hara 'iptables -S XPAM-HA' | grep -q \"$W.*2379,2380\" && on hara 'iptables -S XPAM-HA' | grep -q DROP"
check 'the firewall is installed before Docker at boot' "on hara 'systemctl is-enabled xpam-ha-firewall' | grep -qx enabled"

say "ha join on B"
docker exec hara cat /opt/xpam/config/ha/xpam-ha-join.enc | docker exec -i harb sh -c 'cat > /root/join.enc'
check 'join refuses a wrong bundle passphrase' "! on harb 'cd /opt/xpam-installer && XPAM_HA_BUNDLE_PASSPHRASE=wrong timeout 120 bash ./xpamctl.sh ha join /root/join.enc -y' >/dev/null 2>&1"
on harb "cd /opt/xpam-installer && export $PASSENV && timeout 2400 bash ./xpamctl.sh ha join /root/join.enc -y > /root/ha-join.log 2>&1"; tail -3 <(on harb 'cat /root/ha-join.log')
check 'B is the standby, streaming in sync' "wait_for \"on hara 'curl -s --cacert /opt/xpam/config/ha/certs/ca.crt --cert /opt/xpam/config/ha/certs/node.crt --key /opt/xpam/config/ha/certs/node.key https://$A:8008/cluster' | grep -q sync_standby\" 30"
check 'XPAM services are stopped on the standby' "wait_for \"! on harb 'docker ps --format {{.Names}}' | grep -qx xpam_core\" 12"
check "B's Redis follows A's" "wait_for \"on harb 'docker exec -e REDISCLI_AUTH=\\\$(grep ^REDIS_PASSWORD= /opt/xpam/config/config.txt | cut -d= -f2) xpam_redis redis-cli info replication' | grep -q role:slave\" 12"
check 'recordings are copied to the standby (within ~1 min)' "wait_for \"on harb 'cat /data/xpam/core/data/replay/2026-10-21/rehearsal.cast 2>/dev/null' | grep -q recording\" 30"
tcp() { on "$1" "timeout 4 bash -c 'exec 3<>/dev/tcp/$2/$3'" >/dev/null 2>&1; }
check 'the witness cannot reach the database, Patroni or Redis of A' "! tcp harw $A 5432 && ! tcp harw $A 8008 && ! tcp harw $A 6380 && ! tcp harw $A 6379"
check 'the witness reaches the vote of A' "tcp harw $A 2379"
check "Redis without TLS is not published (only 6380 for replication)" "! tcp harb $A 6379 && tcp harb $A 6380"
DBU=$(on harb 'grep ^DB_USER= /opt/xpam/config/config.txt | cut -d= -f2'); DBP=$(on harb 'grep ^DB_PASSWORD= /opt/xpam/config/config.txt | cut -d= -f2'); DBN=$(on harb 'grep ^DB_NAME= /opt/xpam/config/config.txt | cut -d= -f2')
login_from_b() { on harb "docker run --rm --network host -e PGCONNECT_TIMEOUT=5 postgres:16.15-bookworm psql 'host=$1 user=$DBU password=$DBP dbname=$DBN sslmode=require' -Atqc 'select 1'" 2>/dev/null | grep -qx 1; }
check "XPAM's own containers log in (control for the next check)" "on hara \"docker run --rm --network xpam_net -e PGCONNECT_TIMEOUT=5 postgres:16.15-bookworm psql 'host=postgresql user=$DBU password=$DBP dbname=$DBN' -Atqc 'select 1'\" 2>/dev/null | grep -qx 1"
check 'the other server cannot log in to the database as XPAM (even with the password)' "! login_from_b $A"
check 'Patroni refuses callers without the cluster certificate' "[[ \$(on harb \"curl -sk -o /dev/null -w %{http_code} --max-time 5 https://$A:8008/cluster\") == 000 ]]"
check "the components' shared config holds no secrets" "! on hara 'grep -E \"^(SECRET_KEY|BOOTSTRAP_TOKEN|REDIS_PASSWORD|DB_PASSWORD|HA_[A-Z_]*PASSWORD|BROWSER_KEY|CHAT_AI_DELEGATION_SECRET|REDIS_KOKO_PASSWORD)=\" /opt/xpam/config/config_safe.txt'"
check "the shared config still has what components need (control)" "on hara 'grep -q ^CORE_HOST= /opt/xpam/config/config_safe.txt'"
check "the witness can vote but cannot change XPAM's records" "! on harw 'docker exec xpam_etcd_witness etcdctl --endpoints https://127.0.0.1:2379 --cacert /certs/ca.crt --cert /certs/node.crt --key /certs/node.key put /xpam/xpam/leader xpam-witness' >/dev/null 2>&1"
check 'xpamctl ha status reports both servers' "[[ \$(on hara 'cd /opt/xpam-installer && bash ./xpamctl.sh ha status') == *xpam-b*sync_standby* ]]"
probe() { # node mode [arg]: the probe inside that server's core (alerts | messages <text> | status)
  on "$1" "docker cp /src/tests/ha/ha_probe.py xpam_core:/tmp/p.py >/dev/null && docker exec xpam_core python /tmp/p.py $2 '${3:-}' 2>/dev/null | tail -1"
}
holds_vip() { on "$1" "ip -o -4 addr show" | grep -q " 172.31.9.100/"; }
check 'the console API shows the cluster (primary + synchronous standby)' "[[ \$(probe hara status) == *'API True'*leader*sync_standby*primary* ]]"
check 'no high availability alert while everything is healthy' "wait_for \"[[ \\\$(probe hara alerts) == 'ALERTS []' ]]\" 18"

say "floating address"
on hara 'cd /opt/xpam-installer && bash ./xpamctl.sh ha vip 172.31.9.100/24' >/dev/null
on harb 'cd /opt/xpam-installer && bash ./xpamctl.sh ha vip 172.31.9.100/24' >/dev/null
check 'the primary (A) holds the floating address' "wait_for 'holds_vip hara' 6"
check 'the standby does not' "! holds_vip harb"

say "witness down"
docker stop harw >/dev/null
check 'without the witness XPAM keeps running on A' "sleep 20; on hara \"\$PSQL 'insert into xpam_ha_rehearsal values (\\\$\\\$while-witness-down\\\$\\\$)'\" ; [[ \$(on hara 'curl -s -o /dev/null -w %{http_code} --cacert /opt/xpam/config/ha/certs/ca.crt --cert /opt/xpam/config/ha/certs/node.crt --key /opt/xpam/config/ha/certs/node.key https://$A:8008/primary') == 200 ]]"
check 'the console warns that the witness does not answer' "wait_for \"[[ \\\$(probe hara alerts) == *ha_witness* ]]\" 18"
docker start harw >/dev/null
check 'the warning goes away when the witness is back' "wait_for \"[[ \\\$(probe hara alerts) == 'ALERTS []' ]]\" 24"

say "crash of A"
docker kill hara >/dev/null
start=$(date +%s)
wait_for "[[ \$(on harb 'curl -s -o /dev/null -w %{http_code} --cacert /opt/xpam/config/ha/certs/ca.crt --cert /opt/xpam/config/ha/certs/node.crt --key /opt/xpam/config/ha/certs/node.key https://$B:8008/primary') == 200 ]]" 30
check "B's database takes over by itself ($(( $(date +%s) - start ))s)" "[[ \$(on harb 'curl -s -o /dev/null -w %{http_code} --cacert /opt/xpam/config/ha/certs/ca.crt --cert /opt/xpam/config/ha/certs/node.crt --key /opt/xpam/config/ha/certs/node.key https://$B:8008/primary') == 200 ]]"
wait_for "on harb 'docker ps --format \"{{.Names}} {{.Status}}\"' | grep -q '^xpam_core .*(healthy)'" 120
check "XPAM starts on B by itself ($(( $(date +%s) - start ))s)" "on harb 'docker ps --format \"{{.Names}} {{.Status}}\"' | grep -q '^xpam_core .*(healthy)'"
check 'B has the data written on A' "on harb \"\$PSQL 'select v from xpam_ha_rehearsal'\" | grep -qx seed"
check 'B answers as XPAM (health URL for the load balancer)' "wait_for \"[[ \\\$(on harb 'curl -sk -o /dev/null -w %{http_code} https://127.0.0.1/api/health/') == 200 ]]\" 24"
check "B's Redis is the master" "on harb 'docker exec -e REDISCLI_AUTH=\$(grep ^REDIS_PASSWORD= /opt/xpam/config/config.txt | cut -d= -f2) xpam_redis redis-cli info replication' | grep -q role:master"
check 'the floating address moved to B' "wait_for 'holds_vip harb' 6"
check 'the administrators are told that XPAM moved to B' "wait_for \"[[ \\\$(probe harb messages 'moved to server xpam-b') == 'MESSAGES 1' ]]\" 12"

say "A comes back"
docker start hara >/dev/null
wait_for "on hara 'curl -s --cacert /opt/xpam/config/ha/certs/ca.crt --cert /opt/xpam/config/ha/certs/node.crt --key /opt/xpam/config/ha/certs/node.key https://$A:8008/patroni' | grep -q '\"role\": \"replica\"'" 60
check 'A rejoins as standby (never a second primary)' "on hara 'curl -s --cacert /opt/xpam/config/ha/certs/ca.crt --cert /opt/xpam/config/ha/certs/node.crt --key /opt/xpam/config/ha/certs/node.key https://$A:8008/patroni' | grep -q '\"role\": \"replica\"'"
check 'XPAM services are stopped on A' "wait_for \"! on hara 'docker ps --format {{.Names}}' | grep -qx xpam_core\" 24"
check 'B stays the primary' "[[ \$(on harb 'curl -s -o /dev/null -w %{http_code} --cacert /opt/xpam/config/ha/certs/ca.crt --cert /opt/xpam/config/ha/certs/node.crt --key /opt/xpam/config/ha/certs/node.key https://$B:8008/primary') == 200 ]]"
check 'A does not take the floating address' "! holds_vip hara"

say "planned switchover back to A"
wait_for "on harb 'curl -s --cacert /opt/xpam/config/ha/certs/ca.crt --cert /opt/xpam/config/ha/certs/node.crt --key /opt/xpam/config/ha/certs/node.key https://$B:8008/cluster' | grep -q sync_standby" 30
on harb 'cd /opt/xpam-installer && bash ./xpamctl.sh ha switchover' | tail -1
wait_for "on hara 'docker ps --format \"{{.Names}} {{.Status}}\"' | grep -q '^xpam_core .*(healthy)'" 120
check 'after the switchover XPAM runs on A' "on hara 'docker ps --format \"{{.Names}} {{.Status}}\"' | grep -q '^xpam_core .*(healthy)'"
check 'and is stopped on B' "wait_for \"! on harb 'docker ps --format {{.Names}}' | grep -qx xpam_core\" 24"
check 'the floating address is back on A only' "wait_for 'holds_vip hara' 6 && ! holds_vip harb"

say "replacing every certificate (XPAM keeps running)"
wait_for "on hara 'curl -s --cacert /opt/xpam/config/ha/certs/ca.crt --cert /opt/xpam/config/ha/certs/node.crt --key /opt/xpam/config/ha/certs/node.key https://$A:8008/cluster' | grep -q sync_standby" 30
core_started=$(on hara "docker inspect -f '{{.State.StartedAt}}' xpam_core"); pg_started=$(on hara "docker inspect -f '{{.State.StartedAt}}' xpam_postgresql")
on hara "cd /opt/xpam-installer && export $PASSENV && bash ./xpamctl.sh ha rotate-certs > /root/ha-rotate.log 2>&1"; tail -1 <(on hara 'cat /root/ha-rotate.log')
docker exec hara cat /opt/xpam/config/ha/xpam-ha-join.enc | docker exec -i harb sh -c 'cat > /root/rotate.enc'
on harb "cd /opt/xpam-installer && export $PASSENV && bash ./xpamctl.sh ha apply-certs /root/rotate.enc" | tail -1
docker exec hara cat /opt/xpam/config/ha/xpam-ha-witness.enc | docker exec -i -e XPAM_HA_BUNDLE_PASSPHRASE harw sh -c 'rm -rf /root/w2 && mkdir -p /root/w2 && openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass env:XPAM_HA_BUNDLE_PASSPHRASE | tar xzf - -C /root/w2 && /root/w2/witness.sh' | tail -1
check 'rotate-certs --finish: every machine on the new certificates' "wait_for \"on hara 'cd /opt/xpam-installer && bash ./xpamctl.sh ha rotate-certs --finish' 2>&1 | grep -q Done\" 12"
check 'XPAM and its database were not restarted by the rotation' "[[ \$(on hara \"docker inspect -f '{{.State.StartedAt}}' xpam_core\") == '$core_started' && \$(on hara \"docker inspect -f '{{.State.StartedAt}}' xpam_postgresql\") == '$pg_started' ]]"
check 'replication works with the new certificates' "on hara \"\$PSQL 'insert into xpam_ha_rehearsal values (\\\$\\\$after-rotation\\\$\\\$)'\" && wait_for \"[[ \\\$(on harb \\\"\\\$PSQL 'select count(*) from xpam_ha_rehearsal'\\\") == 3 ]]\" 12"
check 'the old certificates are refused' "[[ \$(on hara 'd=\$(ls -d /opt/xpam/config/ha/certs.before-* | tail -1); curl -s -o /dev/null -w %{http_code} --max-time 5 --cacert \$d/ca.crt --cert \$d/node.crt --key \$d/node.key https://$B:8008/cluster') == 000 ]]"

say "power cut: all three machines at once"
docker kill hara harb harw >/dev/null
sleep 5
docker start harw hara harb >/dev/null
wait_for "[[ \$(on hara 'curl -s -o /dev/null -w %{http_code} --cacert /opt/xpam/config/ha/certs/ca.crt --cert /opt/xpam/config/ha/certs/node.crt --key /opt/xpam/config/ha/certs/node.key https://$A:8008/primary') == 200 || \$(on harb 'curl -s -o /dev/null -w %{http_code} --cacert /opt/xpam/config/ha/certs/ca.crt --cert /opt/xpam/config/ha/certs/node.crt --key /opt/xpam/config/ha/certs/node.key https://$B:8008/primary') == 200 ]]" 60
PRIMARY=hara; STANDBY=harb; PIP=$A
if [[ $(on harb "curl -s -o /dev/null -w %{http_code} --cacert /opt/xpam/config/ha/certs/ca.crt --cert /opt/xpam/config/ha/certs/node.crt --key /opt/xpam/config/ha/certs/node.key https://$B:8008/primary") == 200 ]]; then PRIMARY=harb; STANDBY=hara; PIP=$B; fi
check "after the power cut one server is primary again ($PRIMARY)" "[[ -n $PRIMARY ]]"
check 'XPAM runs on the primary only' "wait_for \"on $PRIMARY 'docker ps --format \\\"{{.Names}} {{.Status}}\\\"' | grep -q '^xpam_core .*(healthy)'\" 60 && wait_for \"! on $STANDBY 'docker ps --format {{.Names}}' | grep -qx xpam_core\" 24"
check 'no data was lost' "[[ \$(on $PRIMARY \"\$PSQL 'select count(*) from xpam_ha_rehearsal'\") == 3 ]]"
check 'the standby follows again (in sync)' "wait_for \"on $PRIMARY 'curl -s --cacert /opt/xpam/config/ha/certs/ca.crt --cert /opt/xpam/config/ha/certs/node.crt --key /opt/xpam/config/ha/certs/node.key https://$PIP:8008/cluster' | grep -q sync_standby\" 30"
check 'the floating address is on the primary' "wait_for 'holds_vip $PRIMARY' 6 && ! holds_vip $STANDBY"
if [[ "$PRIMARY" == harb ]]; then
  on harb 'cd /opt/xpam-installer && bash ./xpamctl.sh ha switchover' | tail -1
  wait_for "on hara 'docker ps --format \"{{.Names}} {{.Status}}\"' | grep -q '^xpam_core .*(healthy)'" 120
fi

say "the second server is rebuilt (disk lost) and joins again"
on harb 'systemctl stop xpam-ha; cd /opt/xpam-installer && bash ./xpamctl.sh down >/dev/null 2>&1; rm -rf /data/xpam/postgresql/data /data/xpam/etcd; sed -i "s/^HA_ENABLED=.*/HA_ENABLED=0/" /opt/xpam/config/config.txt'
on hara "cd /opt/xpam-installer && export $PASSENV && bash ./xpamctl.sh ha join-bundle" >/dev/null
docker exec hara cat /opt/xpam/config/ha/xpam-ha-join.enc | docker exec -i harb sh -c 'cat > /root/join2.enc'
on harb "cd /opt/xpam-installer && export $PASSENV && timeout 2400 bash ./xpamctl.sh ha join /root/join2.enc -y > /root/ha-rejoin.log 2>&1"; tail -2 <(on harb 'cat /root/ha-rejoin.log')
check 'the rebuilt server is the synchronous standby again' "wait_for \"on hara 'curl -s --cacert /opt/xpam/config/ha/certs/ca.crt --cert /opt/xpam/config/ha/certs/node.crt --key /opt/xpam/config/ha/certs/node.key https://$A:8008/cluster' | grep -q sync_standby\" 30"
check 'it has all the data' "wait_for \"[[ \\\$(on harb \\\"\\\$PSQL 'select count(*) from xpam_ha_rehearsal'\\\") == 3 ]]\" 12"
check 'the rebuilt server got the floating address setting from the fresh bundle' "on harb 'grep -q ^HA_VIP=172.31.9.100/24 /opt/xpam/config/config.txt'"

say "back to one server"
on harb 'cd /opt/xpam-installer && bash ./xpamctl.sh ha disable -y' | tail -1
on hara 'cd /opt/xpam-installer && timeout 1200 bash ./xpamctl.sh ha disable -y > /root/ha-disable.log 2>&1'; tail -2 <(on hara 'cat /root/ha-disable.log')
check 'A runs XPAM alone again (no Patroni, no vote)' "wait_for \"on hara 'docker ps --format \\\"{{.Names}} {{.Image}} {{.Status}}\\\"' | grep -q '^xpam_core .*(healthy)'\" 60 && on hara 'docker ps --format {{.Image}}' | grep -q '^postgres:16' && ! on hara 'docker ps --format {{.Names}}' | grep -qx xpam_etcd"
check 'with all its data' "[[ \$(on hara \"\$PSQL 'select count(*) from xpam_ha_rehearsal'\") == 3 ]]"
check 'and without the floating address' "! holds_vip hara"
check 'the single server does not publish its database on the host' "[[ -z \$(on hara 'docker port xpam_postgresql') ]]"
check 'the firewall service is gone' "! on hara 'systemctl is-enabled xpam-ha-firewall' 2>/dev/null | grep -qx enabled"

echo "RESULT: $PASS/$((PASS+FAIL)) passed"
[[ $FAIL -eq 0 ]]
