#!/usr/bin/env bash
# XPAM upgrade rehearsal: an installation of the previous release, upgraded to this one with `xpamctl upgrade`, on a
# simulated server (a privileged Rocky Linux container with its own Docker, memory-capped). Nothing of the live system
# is used. The node's installer is a git checkout of the old release that tracks the new branch, so the upgrade runs
# its real self-update (git pull) first, as on a customer's server.
#   tests/upgrade/rehearsal.sh [old-installer-ref] [old-tag] [new-tag]      (images xpam/*:<tag> local)
# Checks: the old release installs and runs; after the upgrade every service runs the new images under its new name,
# the settings carry the new names (old ones gone, values kept), the data is still there, the services are healthy,
# registered with core, reachable through the gateway, and the AI and database console services run as their users.
set -uo pipefail
OLD_REF=${1:-cd30800}; OLD=${2:-v5.1.39}; NEW=${3:-v5.1.40}
N=xupg; NET=xupgnet
PASS=0; FAIL=0
check() { if eval "$2"; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }
on() { docker exec "$N" bash -lc "$*"; }
say() { echo "== $(date +%T) $*"; }
# Python into core's Django shell on the simulated server (stdin), for the old and the new installation path
core_py() { docker exec -i "$N" docker exec -i xpam_core sh -c 'cd /opt/*/apps && python manage.py shell' 2>/dev/null; }
wait_for() { for _ in $(seq "${2:-60}"); do eval "$1" && return 0; sleep 5; done; return 1; }
cleanup() {
  docker rm -f -v "$N" >/dev/null 2>&1; docker volume rm "$N-docker" >/dev/null 2>&1
  docker network rm "$NET" >/dev/null 2>&1; git -C /opt/xpam-installer branch -D xpam-rehearsal-old >/dev/null 2>&1
}
[[ "${KEEP:-}" == "1" ]] || trap cleanup EXIT
cleanup
git -C /opt/xpam-installer branch xpam-rehearsal-old "$OLD_REF"
NODE_IMAGE=rockylinux/rockylinux:9-ubi-init
docker image inspect xpam-test/rocky-docker:9 >/dev/null 2>&1 && NODE_IMAGE=xpam-test/rocky-docker:9
# the services the rehearsal runs (the renamed ones included); browser, workspace and face recognition stay off
SERVICES=(core gateway web secureconnection webconnector ai)
OPTS="XPAM_VAULT_MODE=none BROWSER_ENABLED=0 WORKSPACE_ENABLED=0 FACE_RECOGNITION_ENABLED=0 SERVER_SIZE=small XPAM_IMAGE_REGISTRY=local"

say "simulated server"
docker network create "$NET" >/dev/null
docker run -d --privileged --name "$N" --hostname "$N" --memory 3g --memory-swap 3g --cpus 2 --network "$NET" \
  -v "$N-docker:/var/lib/docker" -v /opt/xpam-installer:/src:ro "$NODE_IMAGE" >/dev/null
sleep 8
on 'command -v git >/dev/null || for i in $(seq 20); do dnf -y -q install git tar procps-ng iproute python3 openssl >/dev/null 2>&1 && break; sleep 10; done; git config --global --add safe.directory "*"'
wait_for "on 'docker info >/dev/null 2>&1'" 30
check 'the simulated server runs Docker' "on 'docker info >/dev/null 2>&1'"

say "images (old $OLD, new $NEW)"
load() { local tag=$1; shift; local imgs=(); for s in "$@"; do imgs+=("xpam/$s:$tag"); done
  docker save "${imgs[@]}" | docker exec -i "$N" docker load -q >/dev/null; }
# (the old release names its connection images as the new one does: secureconnection, webconnector, ai)
load "$OLD" "${SERVICES[@]}"
docker save postgres:16.15-bookworm redis:7.4.10-bookworm | docker exec -i "$N" docker load -q >/dev/null

say "install $OLD (installer at $OLD_REF)"
on "cd /root && export $OPTS XPAM_INSTALLER_REPO=/src XPAM_INSTALLER_BRANCH=xpam-rehearsal-old AUTO_INSTALL=1 XPAM_SKIP_SELF_UPDATE=1; git -C /src show xpam-rehearsal-old:quick_start.sh > /root/quick_start.sh; timeout 1200 bash /root/quick_start.sh > /root/install1.log 2>&1" || true
# settings as an older installation has them: the reduced setup, a changed SSH port under its old name
on "for kv in $OPTS KOKO_SSH_PORT=2223 KOKO_WEB_PROXY_PORT=5001; do k=\${kv%%=*}; sed -i \"/^\$k=/d\" /opt/xpam/config/config.txt; echo \$kv >> /opt/xpam/config/config.txt; done; cd /opt/xpam-installer && export $OPTS AUTO_INSTALL=1 XPAM_SKIP_SELF_UPDATE=1; timeout 1800 bash ./xpamctl.sh install > /root/install2.log 2>&1"
wait_for "on 'docker ps --format {{.Names}}' | grep -qx xpam_core" 30
check "$OLD is installed and core runs" "on 'docker ps --format {{.Names}}' | grep -qx xpam_core"
check "$OLD runs its connection service under the old service name (koko)" \
  "on 'docker ps --filter label=com.docker.compose.service=koko --format {{.Names}}' | grep -q ."
wait_for "[[ \$(on 'curl -sk -o /dev/null -w %{http_code} https://127.0.0.1/api/health/') == 200 ]]" 60
echo 'from users.models import User; User.objects.get_or_create(username="upgrade.keep", defaults=dict(name="Upgrade Keep", email="upgrade.keep@example.invalid"))' | core_py >/dev/null
check 'data created on the old release' "echo 'from users.models import User; print(\"COUNT\", User.objects.filter(username=\"upgrade.keep\").count())' | core_py | grep -qx 'COUNT 1'"

say "upgrade to $NEW (xpamctl upgrade: the installer updates itself from its repository first)"
load "$NEW" "${SERVICES[@]}"
# as on a customer's server: the installer checkout follows the release branch, which has moved on
on "cd /opt/xpam-installer && git fetch -q origin xpam:refs/remotes/origin/xpam && git branch -q -u origin/xpam"
on "cd /opt/xpam-installer && export AUTO_INSTALL=1 XPAM_IMAGE_REGISTRY=local; timeout 2400 bash ./xpamctl.sh upgrade > /root/upgrade.log 2>&1; echo \$? > /root/upgrade.rc"
check 'the upgrade finished without an error' "[[ \$(on 'cat /root/upgrade.rc') == 0 ]]"
check 'the installer updated itself to the new release' "on 'grep -q \"^export VERSION=$NEW\" /opt/xpam-installer/static.env'"
check "config.txt records $NEW" "on 'grep -qx CURRENT_VERSION=$NEW /opt/xpam/config/config.txt'"

say "after the upgrade"
for svc in core worker gateway web secureconnection webconnector ai; do
  wait_for "on 'docker inspect -f {{.State.Health.Status}} xpam_$svc' 2>/dev/null | grep -qx healthy" 36
  check "xpam_$svc runs $NEW and is healthy" \
    "on 'docker inspect -f \"{{.Config.Image}} {{.State.Health.Status}}\" xpam_$svc' 2>/dev/null | grep -qx \"xpam/$([ $svc = worker ] && echo core || echo $svc):$NEW healthy\""
done
for svc in secureconnection webconnector ai; do
  check "xpam_$svc runs under its new service name" \
    "on 'docker inspect -f \"{{index .Config.Labels \\\"com.docker.compose.service\\\"}}\" xpam_$svc' | grep -qx $svc"
done
check 'no container is left under an old service name' \
  "! on 'docker ps -a --format \"{{.Label \\\"com.docker.compose.service\\\"}}\"' | grep -qE '^(koko|chen|kael|celery)$'"
check 'the settings carry the new names, with their values' \
  "on 'grep -qx SECURECONNECTION_SSH_PORT=2223 /opt/xpam/config/config.txt && grep -qx SECURECONNECTION_WEB_PROXY_PORT=5001 /opt/xpam/config/config.txt'"
check 'the old setting names are gone' "! on 'grep -qE \"^(KOKO|CHEN|KAEL)_\" /opt/xpam/config/config.txt'"
check 'the SSH port is still published on 2223' "on 'docker port xpam_secureconnection' | grep -q ':2223'"
check 'the data is still there' "echo 'from users.models import User; print(\"COUNT\", User.objects.filter(username=\"upgrade.keep\").count())' | core_py | grep -qx 'COUNT 1'"
check 'core is installed under /opt/core (no upstream path)' "on 'docker exec xpam_core test -d /opt/core/apps && ! docker exec xpam_core test -e /opt/jumpserver'"
check 'the gateway serves the API' "[[ \$(on 'curl -sk -o /dev/null -w %{http_code} https://127.0.0.1/api/health/') == 200 ]]"
check 'the gateway serves the console with its CSP' "on 'curl -sk -D - -o /dev/null https://127.0.0.1/web/' | grep -qi \"content-security-policy: default-src 'self'; script-src 'self'\""
check 'the AI service runs as its own user' "on 'docker exec xpam_ai cat /proc/1/status' | awk '/^Uid:/{print \$2}' | grep -qx 10003"
check 'the database console runs as its own user' "on 'docker exec xpam_webconnector cat /proc/1/status' | awk '/^Uid:/{print \$2}' | grep -qx 10004"
check 'the renamed components registered with core' "echo 'from terminal.models import Terminal; print(\"TYPES\", sorted(set(Terminal.objects.filter(is_deleted=False).values_list(\"type\", flat=True))))' | core_py | grep '^TYPES' | grep -q koko"
echo
echo "DONE $PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]] || { on 'tail -25 /root/upgrade.log'; on 'docker ps -a --format "{{.Names}} {{.Image}} {{.Status}}"'; exit 1; }
