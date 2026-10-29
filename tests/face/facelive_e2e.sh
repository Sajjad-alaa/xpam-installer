#!/usr/bin/env bash
# Face recognition end to end on a simulated XPAM server: the facelive engine behind the gateway's /ws/facelive/,
# its service account, enrolment, face sign-in (same person passes, another person fails), the liveness challenge
# (a still photo cannot pass it), an invalid token (4403), an empty camera (face_missing), and the security rules:
# only the engine's own service account uses the face endpoints, no similarity score reaches the engine or the
# page, a finished result is final, many faces that do not match pause face sign-in. The camera is a
# scripted WebSocket client sending frames made from public-domain test photos (xpam-facelive/tests/data).
#   tests/face/facelive_e2e.sh [tag]     (images xpam/core, gateway, facelive:<tag> local; the installer of this tree)
set -uo pipefail
TAG=${1:-v5.1.23-dev}
NET=xfc; X=172.31.10.21
PHOTOS=${PHOTOS:-/opt/xpam-facelive/tests/data}
PASS=0; FAIL=0
check() { if eval "$2"; then echo "PASS $1"; PASS=$((PASS+1)); else echo "FAIL $1"; FAIL=$((FAIL+1)); fi; }
on() { local n=$1; shift; docker exec -i "$n" bash -lc "$*"; }
wait_for() { for _ in $(seq "${2:-60}"); do eval "$1" && return 0; sleep 5; done; return 1; }
say() { echo "== $(date +%T) $*"; }
cleanup() { docker rm -f xfcx >/dev/null 2>&1; docker volume rm xfcx-docker >/dev/null 2>&1; docker network rm "$NET" >/dev/null 2>&1; }
[[ "${KEEP:-}" == "1" ]] || trap cleanup EXIT
cleanup
MIN="XPAM_VAULT_MODE=none KOKO_ENABLED=0 CHEN_ENABLED=0 KAEL_ENABLED=0 BROWSER_ENABLED=0 WORKSPACE_ENABLED=0 WEB_ENABLED=0 WORKER_ENABLED=0 SERVER_SIZE=small XPAM_IMAGE_REGISTRY=local XPAM_VERSION=$TAG FACE_RECOGNITION_ENABLED=true FACE_LIVENESS_MODE=off"
CORE_SHELL="docker exec -i xpam_core bash -c 'cd /opt/jumpserver/apps && python manage.py shell 2>/dev/null'"

say "test server (the installer of this working tree)"
docker network create --subnet 172.31.10.0/24 "$NET" >/dev/null
docker run -d --privileged --name xfcx --hostname xfcx --memory 2600m --memory-swap 2600m --cpus 2 --network $NET --ip $X \
  -v xfcx-docker:/var/lib/docker -v /opt/xpam-installer:/src:ro -v "$PHOTOS":/photos:ro xpam-test/rocky-docker:9 >/dev/null
sleep 8
on xfcx 'systemctl start docker; git config --global --add safe.directory "*"'
on xfcx "cd /root && export $MIN XPAM_INSTALLER_REPO=/src AUTO_INSTALL=1 XPAM_SKIP_SELF_UPDATE=1; timeout 1200 bash /src/quick_start.sh > /root/install1.log 2>&1" || true
# (quick_start clones the committed installer: the working tree's files over it)
on xfcx "cp -a /src/scripts /src/xpamctl.sh /src/compose /src/config-example.txt /opt/xpam-installer/"
docker save "xpam/core:$TAG" "xpam/gateway:$TAG" "xpam/facelive:$TAG" postgres:16.15-bookworm redis:7.4.10-bookworm \
  | docker exec -i xfcx docker load -q >/dev/null
on xfcx "for kv in $MIN; do echo \$kv >> /opt/xpam/config/config.txt; done; cd /opt/xpam-installer && export $MIN AUTO_INSTALL=1 XPAM_SKIP_SELF_UPDATE=1; timeout 1800 bash ./xpamctl.sh install > /root/install2.log 2>&1"
check 'XPAM and the face engine run' "wait_for \"on xfcx 'docker ps --format \\\"{{.Names}} {{.Status}}\\\"' | grep -q '^xpam_facelive .*(healthy)'\" 60 && on xfcx 'docker ps --format \"{{.Names}} {{.Status}}\"' | grep -q '^xpam_core .*(healthy)'"
check 'the engine is a core service account' "wait_for \"on xfcx 'docker logs xpam_facelive 2>&1' | grep -qi 'service account'\" 24"
check 'the gateway routes /ws/facelive/ to it' "[[ \$(on xfcx 'curl -sk -o /dev/null -w %{http_code} https://127.0.0.1/ws/facelive/health') == 200 ]]"
# the photos and the camera script into the engine: its /tmp is a tmpfs on a read-only image (docker cp would write
# under the tmpfs, where the container cannot see the files), so they are streamed in — again after each restart
TO_ENGINE='docker exec xpam_facelive mkdir -p /tmp/photos && for f in /photos/*.jpg; do docker exec -i xpam_facelive sh -c "cat > /tmp/photos/$(basename $f)" < $f; done; test ! -f /root/camera.py || docker exec -i xpam_facelive sh -c "cat > /tmp/camera.py" < /root/camera.py'
on xfcx "$TO_ENGINE"

# the camera: frames made from one photo as a webcam would see the person (a 640x480 view around the face, a little
# noise and shift each time), or an empty room (noise only: a camera never sends the same picture twice)
cat > /tmp/xfc-camera.py <<'PY'
import asyncio, base64, json, random, ssl, sys
import cv2, numpy as np, websockets
token, photo, seconds = sys.argv[1], sys.argv[2], float(sys.argv[3])
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
def webcam_view(img):
    # (the portraits are half-body: a person at a webcam fills more of the picture)
    h, w = img.shape[:2]
    s = 320.0 / w  # (the face is found on a small copy, as the detector expects)
    small = cv2.resize(img, (320, int(h * s)))
    detector = cv2.FaceDetectorYN.create('/opt/facelive/models/face_detection_yunet_2023mar.onnx', '',
                                         (small.shape[1], small.shape[0]))
    faces = detector.detect(small)[1]
    x, y, fw, fh = faces[0][:4] / s
    cw = min(w, fw * 3.0); ch = min(h, cw * 3 / 4); cw = ch * 4 / 3
    cx, cy = x + fw / 2, y + fh / 2
    x0 = int(max(0, min(w - cw, cx - cw / 2))); y0 = int(max(0, min(h - ch, cy - ch / 2)))
    return cv2.resize(img[y0:y0 + int(ch), x0:x0 + int(cw)], (640, 480))
base = None if photo == 'blank' else webcam_view(cv2.imread(photo))
def frame():
    img = np.full((480, 640, 3), 30, np.uint8) if base is None else base.copy()
    if base is not None:
        img = np.roll(img, random.randint(-3, 3), axis=1)
    img = cv2.add(img, np.random.randint(0, 6, img.shape, dtype=np.uint8))
    ok, buf = cv2.imencode('.jpg', img, [cv2.IMWRITE_JPEG_QUALITY, 85])
    return 'data:image/jpeg;base64,' + base64.b64encode(buf.tobytes()).decode()
async def main():
    last = {}
    try:
        async with websockets.connect(f'wss://xpam_gateway/ws/facelive/capture/?token={token}&mode=capture', ssl=ctx,
                                      max_size=8_000_000) as ws:
            loop = asyncio.get_event_loop(); end = loop.time() + seconds
            await ws.recv()  # ready
            while loop.time() < end:
                await ws.send(json.dumps({'type': 'frame', 'image': frame()}))
                msg = json.loads(await asyncio.wait_for(ws.recv(), 15))
                if msg.get('type') == 'frame_result':
                    last = msg['flow']
                    if last.get('finished'):
                        break
                elif msg.get('type') == 'error' and msg.get('fatal'):
                    print('RESULT error', msg.get('message')); return
                await asyncio.sleep(0.3)
    except websockets.exceptions.ConnectionClosed as e:
        print('RESULT closed', e.code); return
    print('RESULT', last.get('status'), 'guidance=%s' % last.get('guidance'), 'finished=%s' % last.get('finished'),
          'similarity=%s' % last.get('similarity'))
asyncio.run(main())
PY
docker cp /tmp/xfc-camera.py xfcx:/root/camera.py
on xfcx "$TO_ENGINE"
camera() {  # (no RESULT line: the client failed — its last lines are shown)
  local out; out=$(on xfcx "docker exec xpam_facelive python /tmp/camera.py $1 $2 ${3:-45}" 2>&1)
  grep '^RESULT' <<<"${out}" | tail -1 || true
  grep -q '^RESULT' <<<"${out}" || tail -4 <<<"${out}" | sed 's/^/    client: /' >&2
}
new_token() {  # a capture token of the signed-in admin (as the console's face dialog asks for one)
  printf '%s\n' "from django.test import Client; from users.models import User
c = Client(HTTP_HOST='localhost'); c.force_login(User.objects.get(username='admin'))
print('token', c.post('/api/v1/authentication/face/context/').json()['token'])" | on xfcx "$CORE_SHELL" | grep '^token ' | cut -d' ' -f2
}
context() {  # what core recorded for a token
  printf '%s\n' "from django.core.cache import cache; from authentication.const import FACE_CONTEXT_CACHE_KEY_PREFIX as P
c = cache.get(f'{P}_$1') or {}
print('ctx', c.get('is_finished'), c.get('success'), bool(c.get('face_code')), (c.get('error_message') or '')[:60])" \
    | on xfcx "$CORE_SHELL" | grep '^ctx '
}

say "enrolment (liveness off for the scripted camera)"
T=$(new_token); R=$(camera "$T" /tmp/photos/person_a_1.jpg 60); echo "  $R"; C=$(context "$T"); echo "  $C"
check 'enrolment completes and core has the face code' "[[ '$R' == 'RESULT enrollment_complete'* && '$C' == 'ctx True True True'* ]]"
printf '%s\n' "from django.core.cache import cache; from authentication.const import FACE_CONTEXT_CACHE_KEY_PREFIX as P
from users.models import User
u = User.objects.get(username='admin'); u.face_vector = cache.get(f'{P}_$T')['face_code']; u.save(update_fields=['face_vector'])
print('enrolled', u.is_face_code_set)" | on xfcx "$CORE_SHELL" | grep '^enrolled'

say "face sign-in"
T=$(new_token); R=$(camera "$T" /tmp/photos/person_a_2.jpg 45); echo "  $R"; C=$(context "$T"); echo "  $C"; SAME=$R
check 'the same person (another photo) signs in' "[[ '$R' == 'RESULT auth_success'* && '$C' == 'ctx True True True'* ]]"
OK=$(printf '%s\n' "from django.core.cache import cache; from authentication.const import FACE_CONTEXT_CACHE_KEY_PREFIX as P
from users.models import User
print('check', User.objects.get(username='admin').check_face(cache.get(f'{P}_$T')['face_code']))" | on xfcx "$CORE_SHELL" | grep '^check')
check "... and core's own check accepts that face code ($OK)" "[[ '$OK' == 'check True' ]]"
T=$(new_token); R=$(camera "$T" /tmp/photos/person_b_1.jpg 45); echo "  $R"; OTHER=$R
check 'another person is refused' "[[ '$R' == 'RESULT auth_failed'* ]]"
T=$(new_token); R=$(camera "$T" blank 20); echo "  $R"
check 'an empty camera is told face_missing' "[[ '$R' == *'guidance=face_missing'* ]]"
R=$(camera "0123456789abcdef0123456789abcdef" /tmp/photos/person_a_2.jpg 10); echo "  $R"
check 'an invalid token is closed with 4403' "[[ '$R' == 'RESULT closed 4403' ]]"

say "security: the engine's endpoints, no score, a final result, a pause after many faces that do not match"
SEC=$(printf '%s\n' "from django.test import Client; from django.core.cache import cache
from authentication.const import FACE_CONTEXT_CACHE_KEY_PREFIX as P
from terminal.models import Terminal; from users.models import User
import uuid
J = 'application/json'
admin = User.objects.get(username='admin'); code = str(admin.face_vector)
engine = Terminal.objects.filter(type='facelive', is_deleted=False).first().user
other = User.objects.create(username='svc-' + uuid.uuid4().hex[:8], name='another component', is_service_account=True)
Terminal.objects.create(name=other.username, type='koko', user=other)
c = Client(HTTP_HOST='localhost'); c.force_login(admin)
tok = c.post('/api/v1/authentication/face/context/').json()['token']
o = Client(HTTP_HOST='localhost'); o.force_login(other)
e = Client(HTTP_HOST='localhost'); e.force_login(engine)
print('other', o.get(f'/api/v1/authentication/face/engine/context/?token={tok}').status_code,
      o.post('/api/v1/authentication/face/engine/compare/', {'token': tok, 'face_code': code}, content_type=J).status_code,
      o.post('/api/v1/authentication/face/callback/', {'token': tok, 'success': True, 'face_code': code}, content_type=J).status_code)
r = e.post('/api/v1/authentication/face/engine/compare/', {'token': tok, 'face_code': code}, content_type=J)
print('compare', r.status_code, ','.join(sorted(r.json())))
e.post('/api/v1/authentication/face/callback/', {'token': tok, 'success': False, 'error_message': 'no'}, content_type=J)
r = e.post('/api/v1/authentication/face/callback/', {'token': tok, 'success': True, 'face_code': code}, content_type=J)
print('late', r.status_code, cache.get(f'{P}_{tok}')['success'])
cache.set(f'FACE_ENGINE_FAILS_{admin.id}', 30, 900)
print('paused')" | on xfcx "$CORE_SHELL" | grep -E '^(other|compare|late|paused)')
echo "${SEC}" | sed 's/^/  /'
check 'another component (SSH/RDP service account) cannot use the face endpoints' "grep -q '^other 403 403 403$' <<<'${SEC}'"
check 'a comparison answers yes or no, with no similarity score' "grep -q '^compare 200 matched$' <<<'${SEC}'"
check 'the page is shown no score either (1.0 or 0.0 only)' "[[ '$SAME' == *'similarity=1.0' && '$OTHER' == *'similarity=0.0' ]]"
check 'a finished result cannot be turned into a success' "grep -q '^late 400 False$' <<<'${SEC}'"
T=$(new_token); R=$(camera "$T" /tmp/photos/person_a_2.jpg 10); echo "  $R"
check 'after many faces that do not match, face sign-in waits (even the right face)' "[[ '$R' == 'RESULT closed 4403' ]]"
printf '%s\n' "from django.core.cache import cache; from users.models import User
cache.delete(f\"FACE_ENGINE_FAILS_{User.objects.get(username='admin').id}\")" | on xfcx "$CORE_SHELL" >/dev/null

say "liveness on: a still photo of the right person"
on xfcx "sed -i 's/^FACE_LIVENESS_MODE=.*/FACE_LIVENESS_MODE=motion/' /opt/xpam/config/config.txt; cd /opt/xpam-installer && bash ./xpamctl.sh start >/dev/null 2>&1"
wait_for "on xfcx 'docker ps --format \"{{.Names}} {{.Status}}\"' | grep -q '^xpam_facelive .*(healthy)'" 30
on xfcx "$TO_ENGINE"
T=$(new_token); R=$(camera "$T" /tmp/photos/person_a_2.jpg 60); echo "  $R"
check 'a still photo does not pass the head-movement challenge' "[[ '$R' != 'RESULT auth_success'* && -n '$R' ]]"
check 'no image or face code in the engine log' "! on xfcx 'docker logs xpam_facelive 2>&1' | grep -qE 'xpamf1:|data:image'"

echo "RESULT: $PASS/$((PASS+FAIL)) passed"
[[ $FAIL -eq 0 ]]
