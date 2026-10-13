#!/usr/bin/env bash

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

test_dir="${TEST_TMP_ROOT}/xpam-images"
mkdir -p "${test_dir}"
export JS_CONFIG_DIR="${test_dir}"
cp "${TEST_ROOT}/config-example.txt" "${test_dir}/config.txt"
. "${TEST_ROOT}/scripts/utils.sh"

manifest=$(get_offline_image_manifest)
for image in core gateway web workspace secureconnection webconnector ai; do
  assert_contains "${manifest}" "xpam/${image}:${XPAM_DEFAULT_VERSION}	xpam/${image}:${XPAM_DEFAULT_VERSION}	2" \
    "XPAM image ${image} must be local-only by default"
done
for image in core web koko chen kael; do
  if [[ "${manifest}" == *"jumpserver/${image}:"* ]]; then
    fail "upstream ${image} image must be replaced by its XPAM image"
  fi
done
assert_eq "xpam/ai:${XPAM_DEFAULT_VERSION}" "$(get_images | tr ' ' '\n' | grep '/ai:')" 'get_images must list the XPAM runtime tag'
assert_eq 'v5.0.0' "${XPAM_DEFAULT_VERSION}" 'XPAM images must not carry the upstream -ce suffix'
printf 'PASS: XPAM services map to local-only XPAM images\n'

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
  VERSION=v5.0.0-ce command docker compose -f compose/core.yml -f compose/koko.yml -f compose/chen.yml \
    -f compose/kael.yml -f compose/gateway.yml -f compose/web.yml -f compose/workspace.yml -f compose/network.yml config --images 2>/dev/null | sort -u
) || true
if [[ -n "${rendered}" ]]; then
  for image in core gateway web workspace secureconnection webconnector ai; do
    assert_contains "${rendered}" "xpam/${image}:v5.0.0" "compose must default to the XPAM ${image} image"
  done
  printf 'PASS: compose files default to the XPAM images\n'
fi
