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
on hara "cd /opt/xpam-installer && nohup bash ./xpamctl.sh ha init $A $B $W -y > /root/ha-init.log 2>&1 &"
wait_for "on hara 'test -s /opt/xpam/config/ha/xpam-ha-witness.tgz'" 60
check 'init prepared the witness and join bundles' "on hara 'test -s /opt/xpam/config/ha/xpam-ha-join.tgz'"
check 'the witness bundle holds no XPAM secrets' "! on hara 'tar xzOf /opt/xpam/config/ha/xpam-ha-witness.tgz 2>/dev/null' | grep -q SECRET_KEY"

say "witness"
# the witness: Docker CE only (classic storage driver: the simulated server's own disk is an overlay)
on harw 'dnf -y -q install dnf-plugins-core >/dev/null 2>&1; dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo >/dev/null 2>&1; dnf -y -q install docker-ce docker-ce-cli containerd.io >/dev/null 2>&1; mkdir -p /etc/docker; echo "{\"features\":{\"containerd-snapshotter\":false}}" > /etc/docker/daemon.json; systemctl enable --now docker >/dev/null 2>&1; docker version --format "{{.Server.Version}}"' | tail -1
docker save gcr.io/etcd-development/etcd:v3.5.21 | docker exec -i harw docker load -q >/dev/null
docker exec hara cat /opt/xpam/config/ha/xpam-ha-witness.tgz | docker exec -i harw sh -c 'mkdir -p /root/w && tar xzf - -C /root/w'
on harw '/root/w/witness.sh' | tail -1
wait_for "on hara 'grep -q \"This server is the primary\" /root/ha-init.log'" 120
check 'A is the primary after init' "[[ \$(on hara 'curl -s -o /dev/null -w %{http_code} http://$A:8008/primary') == 200 ]]"
check 'XPAM runs on A under high availability' "wait_for \"on hara 'docker ps --format \\\"{{.Names}} {{.Status}}\\\"' | grep -q '^xpam_core .*(healthy)'\" 60"
check 'the seeded data survived the switch to Patroni' "on hara \"\$PSQL 'select v from xpam_ha_rehearsal'\" | grep -qx seed"
check 'the agent runs on A' "on hara 'systemctl is-active xpam-ha' | grep -qx active"
check 'the replication ports accept only the other server and the witness' "on hara 'iptables -S XPAM-HA' | grep -q \"$B\" && on hara 'iptables -S XPAM-HA' | grep -q DROP"

say "ha join on B"
docker exec hara cat /opt/xpam/config/ha/xpam-ha-join.tgz | docker exec -i harb sh -c 'cat > /root/join.tgz'
on harb "cd /opt/xpam-installer && timeout 2400 bash ./xpamctl.sh ha join /root/join.tgz -y > /root/ha-join.log 2>&1"; tail -3 <(on harb 'cat /root/ha-join.log')
check 'B is the standby, streaming in sync' "wait_for \"on hara 'curl -s http://$A:8008/cluster' | grep -q sync_standby\" 30"
check 'XPAM services are stopped on the standby' "wait_for \"! on harb 'docker ps --format {{.Names}}' | grep -qx xpam_core\" 12"
check "B's Redis follows A's" "wait_for \"on harb 'docker exec -e REDISCLI_AUTH=\\\$(grep ^REDIS_PASSWORD= /opt/xpam/config/config.txt | cut -d= -f2) xpam_redis redis-cli info replication' | grep -q role:slave\" 12"
check 'recordings are copied to the standby (within ~1 min)' "wait_for \"on harb 'cat /data/xpam/core/data/replay/2026-10-21/rehearsal.cast 2>/dev/null' | grep -q recording\" 30"
check 'xpamctl ha status reports both servers' "[[ \$(on hara 'cd /opt/xpam-installer && bash ./xpamctl.sh ha status') == *xpam-b*sync_standby* ]]"
API='docker exec xpam_core python -c "
import os, django; os.environ.setdefault(\"DJANGO_SETTINGS_MODULE\", \"jumpserver.settings\"); django.setup()
from django.conf import settings; settings.ALLOWED_HOSTS = [\"*\"]
from rest_framework.test import APIClient; from users.models import User
c = APIClient(); c.force_authenticate(User.objects.get(username=\"admin\"))
d = c.get(\"/api/v1/settings/ha/status/\").json()
print(\"API\", d.get(\"enabled\"), sorted(m[\"role\"] for m in d.get(\"members\", [])), (d.get(\"agent\") or {}).get(\"role\"))" 2>/dev/null'
check 'the console API shows the cluster (primary + synchronous standby)' "[[ \$(on hara \"\$API\") == *'API True'*leader*sync_standby*primary* ]]"

say "crash of A"
docker kill hara >/dev/null
start=$(date +%s)
wait_for "[[ \$(on harb 'curl -s -o /dev/null -w %{http_code} http://$B:8008/primary') == 200 ]]" 30
check "B's database takes over by itself ($(( $(date +%s) - start ))s)" "[[ \$(on harb 'curl -s -o /dev/null -w %{http_code} http://$B:8008/primary') == 200 ]]"
wait_for "on harb 'docker ps --format \"{{.Names}} {{.Status}}\"' | grep -q '^xpam_core .*(healthy)'" 120
check "XPAM starts on B by itself ($(( $(date +%s) - start ))s)" "on harb 'docker ps --format \"{{.Names}} {{.Status}}\"' | grep -q '^xpam_core .*(healthy)'"
check 'B has the data written on A' "on harb \"\$PSQL 'select v from xpam_ha_rehearsal'\" | grep -qx seed"
check 'B answers as XPAM (health URL for the load balancer)' "wait_for \"[[ \\\$(on harb 'curl -sk -o /dev/null -w %{http_code} https://127.0.0.1/api/health/') == 200 ]]\" 24"
check "B's Redis is the master" "on harb 'docker exec -e REDISCLI_AUTH=\$(grep ^REDIS_PASSWORD= /opt/xpam/config/config.txt | cut -d= -f2) xpam_redis redis-cli info replication' | grep -q role:master"

say "A comes back"
docker start hara >/dev/null
wait_for "on hara 'curl -s http://$A:8008/patroni' | grep -q '\"role\": \"replica\"'" 60
check 'A rejoins as standby (never a second primary)' "on hara 'curl -s http://$A:8008/patroni' | grep -q '\"role\": \"replica\"'"
check 'XPAM services are stopped on A' "wait_for \"! on hara 'docker ps --format {{.Names}}' | grep -qx xpam_core\" 24"
check 'B stays the primary' "[[ \$(on harb 'curl -s -o /dev/null -w %{http_code} http://$B:8008/primary') == 200 ]]"

say "planned switchover back to A"
wait_for "on harb 'curl -s http://$B:8008/cluster' | grep -q sync_standby" 30
on harb 'cd /opt/xpam-installer && bash ./xpamctl.sh ha switchover' | tail -1
wait_for "on hara 'docker ps --format \"{{.Names}} {{.Status}}\"' | grep -q '^xpam_core .*(healthy)'" 120
check 'after the switchover XPAM runs on A' "on hara 'docker ps --format \"{{.Names}} {{.Status}}\"' | grep -q '^xpam_core .*(healthy)'"
check 'and is stopped on B' "wait_for \"! on harb 'docker ps --format {{.Names}}' | grep -qx xpam_core\" 24"

echo "RESULT: $PASS/$((PASS+FAIL)) passed"
[[ $FAIL -eq 0 ]]
