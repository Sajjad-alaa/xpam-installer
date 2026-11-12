#!/usr/bin/env bash
# The remote browser's egress proxy, in the browser image with the given source and the container settings of
# compose/browser.yml (nothing of the live system is used): proxy rules (proxy_test.py), and a real session — Xvfb,
# Chromium, guard, proxy — whose page asks for loopback (the DevTools ports) and for another internal machine that
# is not on the asset's list (session_test.py), with Chromium's renderers sandboxed.
#   tests/browser/run.sh [browser-image] [browser-source-dir]
set -uo pipefail
IMAGE=${1:-xpam/browser:rn}
SRC=${2:-/opt/xpam-secureconnection/browser}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN=(--cap-drop ALL --security-opt no-new-privileges:true --security-opt seccomp=unconfined --shm-size 1g --tmpfs /tmp:size=2g
     -v "$SRC:/src:ro" -v "$HERE:/t:ro" --entrypoint python3)
cleanup() { docker rm -f xbt-other >/dev/null 2>&1; docker network rm xbt >/dev/null 2>&1; }
cleanup; trap cleanup EXIT
docker network create xbt >/dev/null
docker run -d --rm --name xbt-other --network xbt --entrypoint python3 "$IMAGE" -m http.server 8000 >/dev/null
sleep 2
OTHER=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' xbt-other)
docker run --rm --network xbt "${RUN[@]}" "$IMAGE" /t/proxy_test.py 2>&1 | grep -E "^(PASS|FAIL)|DONE"
out=$(docker run --rm --network xbt "${RUN[@]}" "$IMAGE" /t/session_test.py "$OTHER:8000" 2>&1)
echo "$out" | grep -E "page requests|renderers"
reached=$(docker logs xbt-other 2>&1 | grep -c 'GET /x')
echo "other internal machine reached: $reached"
ok=1
echo "$out" | grep -q "page requests: [1-9]" || ok=0
echo "$out" | grep -q "loopback requests: \[\]" || ok=0
[ "$reached" = 0 ] || ok=0
# (compose/browser.yml lets Chromium sandbox its renderers: every renderer in its own user namespace)
echo "$out" | grep -qE "renderers: ([1-9][0-9]*) \| in their own user namespace \(sandboxed\): \1$" || ok=0
if [ "$ok" = 1 ]; then
  echo "SESSION PASS: the page loads; loopback and the unlisted internal machine are refused; renderers sandboxed"
else
  echo "SESSION FAIL"; exit 1
fi
