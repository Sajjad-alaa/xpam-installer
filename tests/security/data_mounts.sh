#!/usr/bin/env bash
# Sets APPS_MOUNT, the `docker run -v` arguments that mount a source tree at /opt/jumpserver/apps together with the
# image's data files: the leaked-password list, the IP location databases and the compiled English messages. The
# repository does not carry them (core.Dockerfile keeps them from the base image); without them `migrate` stops in a
# post-migrate step (no permissions are created, the server does not start) when a source tree replaces the image's code.
# A file cannot be mounted into a read-only directory mount where it does not exist, so the source tree and the data
# files are merged into a copy (rsync, fast) that is mounted instead; the repository is not touched.
#   source tests/security/data_mounts.sh <core-image> <apps-dir>   ->  APPS_MOUNT=( -v <merged>:/opt/jumpserver/apps:ro )
IMAGE=${1:?usage: data_mounts.sh <core-image> <apps-dir>}
SRC_APPS=${2:?usage: data_mounts.sh <core-image> <apps-dir>}
ROOT=${XPAM_TEST_DATA_CACHE:-/tmp/xpam-test-data}
IMAGE_ID=$(docker image inspect -f '{{.Id}}' "$IMAGE" | tr -d ':' | cut -c7-22)
DATA="$ROOT/data-$IMAGE_ID"
if [ ! -d "$DATA" ]; then
  mkdir -p "$DATA"; cid=$(docker create "$IMAGE")
  for f in $(docker run --rm --entrypoint sh "$IMAGE" -c 'cd /opt/jumpserver/apps && find . -name leak_passwords.db \
      -o -name GeoLite2-City.mmdb -o -name ipipfree.ipdb -o -path "./i18n/core/en/LC_MESSAGES/*.mo"'); do
    mkdir -p "$DATA/$(dirname "$f")"; docker cp -q "$cid:/opt/jumpserver/apps/$f" "$DATA/$f"
  done
  docker rm "$cid" >/dev/null
fi
MERGED="$ROOT/merged-$(echo "$SRC_APPS" | md5sum | cut -c1-12)"
mkdir -p "$MERGED"
rsync -a --delete --exclude __pycache__ --exclude '*.pyc' "$SRC_APPS"/ "$MERGED"/
cp -a "$DATA"/. "$MERGED"/
APPS_MOUNT=(-v "$MERGED":/opt/jumpserver/apps:ro)
