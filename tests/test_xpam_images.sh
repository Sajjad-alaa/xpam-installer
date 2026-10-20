#!/usr/bin/env bash

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

test_dir="${TEST_TMP_ROOT}/xpam-images"
mkdir -p "${test_dir}"
export JS_CONFIG_DIR="${test_dir}"
cp "${TEST_ROOT}/config-example.txt" "${test_dir}/config.txt"
. "${TEST_ROOT}/scripts/utils.sh"

# Default: the XPAM images come from the registry built into static.env
manifest=$(get_offline_image_manifest)
for image in core gateway web workspace secureconnection webconnector ai; do
  assert_contains "${manifest}" "${XPAM_DEFAULT_IMAGE_REGISTRY}/${image}:${XPAM_DEFAULT_VERSION}	xpam/${image}:${XPAM_DEFAULT_VERSION}" \
    "XPAM image ${image} must be downloaded from the built-in registry by default"
done
if [[ "${manifest}" == *'	2'* ]]; then
  fail 'no image may be local-only on a default installation'
fi
assert_eq 'ghcr.io' "$(get_xpam_registry_host)" 'registry host'
assert_eq 'sajjad-alaa' "$(get_xpam_registry_owner)" 'registry owner'
printf 'PASS: a default installation downloads the XPAM images from the built-in registry\n'

# XPAM_IMAGE_REGISTRY=local: images built or loaded on this server, never downloaded
printf '%s\n' 'XPAM_IMAGE_REGISTRY=local' >>"${test_dir}/config.txt"
manifest=$(get_offline_image_manifest)
for image in core gateway web workspace secureconnection webconnector ai; do
  assert_contains "${manifest}" "xpam/${image}:${XPAM_DEFAULT_VERSION}	xpam/${image}:${XPAM_DEFAULT_VERSION}	2" \
    "XPAM image ${image} must be local-only with XPAM_IMAGE_REGISTRY=local"
done
for image in core web koko chen kael; do
  if [[ "${manifest}" == *"jumpserver/${image}:"* ]]; then
    fail "upstream ${image} image must be replaced by its XPAM image"
  fi
done
assert_eq '' "$(get_xpam_image_registry)" 'local must disable the registry'
assert_eq "xpam/ai:${XPAM_DEFAULT_VERSION}" "$(get_images | tr ' ' '\n' | grep '/ai:')" 'get_images must list the XPAM runtime tag'
assert_eq 'v5.1.15' "${XPAM_DEFAULT_VERSION}" 'XPAM images must not carry the upstream -ce suffix'
printf 'PASS: XPAM_IMAGE_REGISTRY=local maps the services to local-only XPAM images\n'

printf '%s\n' 'XPAM_VERSION=v5.0.0-xpam1' 'XPAM_NAMESPACE=acme/' 'XPAM_IMAGE_REGISTRY=ghcr.io/owner/' >>"${test_dir}/config.txt"
manifest=$(get_offline_image_manifest)
assert_contains "${manifest}" 'ghcr.io/owner/secureconnection:v5.0.0-xpam1	acme/secureconnection:v5.0.0-xpam1' \
  'a configured XPAM registry must become the exact pull source'
if [[ "${manifest}" == *'	2'* ]]; then
  fail 'images with a registry must not be marked local-only'
fi
printf 'PASS: XPAM_VERSION, XPAM_NAMESPACE and XPAM_IMAGE_REGISTRY are honoured\n'

docker_calls="${test_dir}/docker-calls"
present_image=''
docker() {
  printf '%s\n' "$*" >>"${docker_calls}"
  case "$1 ${2:-}" in
    'image inspect') [[ "${*: -1}" == "${present_image}" ]] ;;
    *) fail "Unexpected Docker command: $*" ;;
  esac
}

: >"${docker_calls}"
present_image='xpam/core:test'
pull_image 'xpam/core:test' 'xpam/core:test' 2 >"${test_dir}/pull.log"
assert_contains "$(cat "${test_dir}/pull.log")" 'XPAM image present'

present_image=''
if pull_image 'xpam/core:test' 'xpam/core:test' 2 >"${test_dir}/pull.log" 2>&1; then
  fail 'a missing local-only XPAM image must fail instead of being pulled'
fi
assert_contains "$(cat "${test_dir}/pull.log")" 'XPAM image not found'
if grep -q '^pull' "${docker_calls}"; then
  fail 'local-only XPAM images must never be pulled from Docker Hub'
fi
printf 'PASS: missing XPAM images fail without contacting Docker Hub\n'

rendered=$(
  cd "${TEST_ROOT}"
  VERSION=v5.1.15 command docker compose --env-file /dev/null -f compose/core.yml -f compose/koko.yml -f compose/chen.yml \
    -f compose/kael.yml -f compose/gateway.yml -f compose/web.yml -f compose/workspace.yml -f compose/network.yml config --images 2>/dev/null | sort -u
) || true
if [[ -n "${rendered}" ]]; then
  for image in core gateway web workspace secureconnection webconnector ai; do
    assert_contains "${rendered}" "xpam/${image}:v5.1.15" "compose must default to the XPAM ${image} image"
  done
  printf 'PASS: compose files default to the XPAM images\n'
fi

# XPAM images keep one tag across rebuilds: a copy already on the server must still be refreshed
docker() {
  printf '%s\n' "$*" >>"${docker_calls}"
  case "$1 ${2:-}" in
    'image inspect') return 0 ;;
    pull\ *|tag\ *) return 0 ;;
    *) fail "Unexpected Docker command: $*" ;;
  esac
}
export BUILD_ARCH=${BUILD_ARCH:-x86_64}
: >"${docker_calls}"
pull_image 'ghcr.io/owner/core:test' 'acme/core:test' 1 >"${test_dir}/pull.log" 2>&1 || { cat "${test_dir}/pull.log"; fail "refresh pull failed"; }
if ! grep -q '^pull .*ghcr.io/owner/core:test' "${docker_calls}"; then
  fail 'an XPAM registry image that is already present must be pulled again'
fi
if ! grep -q '^tag ghcr.io/owner/core:test acme/core:test' "${docker_calls}"; then
  fail 'the refreshed XPAM image must be tagged with its runtime name'
fi
: >"${docker_calls}"
pull_image 'docker.io/library/redis:test' 'redis:test' 1 >"${test_dir}/pull.log" 2>&1
if grep -q '^pull' "${docker_calls}"; then
  fail 'third-party images that are already present must not be pulled again'
fi
printf 'PASS: XPAM registry images are refreshed even when a copy is already present\n'

# Registry access check: an unattended run without credentials stops with instructions
docker() {
  printf '%s\n' "$*" >>"${docker_calls}"
  case "$1 ${2:-}" in
    'manifest inspect')
      if [[ -f "${test_dir}/logged-in" ]]; then
        return 0
      fi
      echo 'unauthorized' >&2
      return 1
      ;;
    login\ *)
      cat >"${test_dir}/login-stdin"
      : >"${test_dir}/logged-in"
      ;;
    *) fail "Unexpected Docker command: $*" ;;
  esac
}
: >"${docker_calls}"
rm -f "${test_dir}/logged-in"
if AUTO_INSTALL=1 ensure_xpam_registry_access >"${test_dir}/access.log" 2>&1 </dev/null; then
  fail 'missing registry access must stop the installation'
fi
assert_contains "$(cat "${test_dir}/access.log")" 'docker login ghcr.io -u owner' 'the sign-in command must be shown'
assert_contains "$(cat "${test_dir}/access.log")" 'read:packages' 'the token scope must be named'
if grep -q '^login' "${docker_calls}"; then
  fail 'an unattended run must not try to sign in without credentials'
fi
printf 'PASS: missing registry access stops an unattended run with instructions\n'

# ... and signs in by itself when a token is passed in the environment
: >"${docker_calls}"
AUTO_INSTALL=1 XPAM_REGISTRY_USER=robot XPAM_REGISTRY_TOKEN=secret-token \
  ensure_xpam_registry_access >"${test_dir}/access.log" 2>&1 </dev/null ||
  { cat "${test_dir}/access.log"; fail 'a token from the environment must give access'; }
assert_contains "$(cat "${docker_calls}")" 'login ghcr.io -u robot --password-stdin' 'sign-in must use stdin for the token'
assert_eq 'secret-token' "$(cat "${test_dir}/login-stdin")" 'the token must be passed on stdin'
if grep -q 'secret-token' "${docker_calls}" "${test_dir}/access.log"; then
  fail 'the token must never appear on a command line or in the output'
fi
printf 'PASS: a registry token from the environment is used without being printed\n'

# A failure that is not about signing in must not ask for credentials
docker() {
  printf '%s\n' "$*" >>"${docker_calls}"
  case "$1 ${2:-}" in
    'manifest inspect') echo 'http: server gave HTTP response to HTTPS client' >&2; return 1 ;;
    *) fail "Unexpected Docker command: $*" ;;
  esac
}
: >"${docker_calls}"
AUTO_INSTALL=1 ensure_xpam_registry_access >"${test_dir}/access.log" 2>&1 </dev/null ||
  fail 'a registry problem that is not about signing in must be left to the download step'
printf 'PASS: only sign-in problems trigger the sign-in help\n'

# Local-only installations never contact a registry
printf '%s\n' 'XPAM_IMAGE_REGISTRY=local' >>"${test_dir}/config.txt"
: >"${docker_calls}"
ensure_xpam_registry_access >/dev/null 2>&1 || fail 'local images need no registry access'
if [[ -s "${docker_calls}" ]]; then
  fail 'XPAM_IMAGE_REGISTRY=local must not contact any registry'
fi
printf 'PASS: XPAM_IMAGE_REGISTRY=local never contacts a registry\n'
