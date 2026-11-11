#!/usr/bin/env bash

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

test_dir="${TEST_TMP_ROOT}/upgrade"
mkdir -p "${test_dir}"
export JS_CONFIG_DIR="${test_dir}"
cp "${TEST_ROOT}/config-example.txt" "${test_dir}/config.txt"

. "${TEST_ROOT}/scripts/7_upgrade.sh" ''

check_root() { return 1; }
docker() {
  [[ "${1:-}" == "ps" ]]
}
remove_config SECURECONNECTION_WEB_PROXY_PORT
remove_config WEB_PROXY_ALLOWED_HOSTS
VERSION=v4.0.0-ce
upgrade_config
assert_eq '5001' "$(get_config SECURECONNECTION_WEB_PROXY_PORT)" 'upgrade must add the default Web Proxy port'
assert_eq 'localhost,127.0.0.1' "$(get_config WEB_PROXY_ALLOWED_HOSTS)" 'upgrade must add the safe Web Proxy allowlist'
set_config SECURECONNECTION_WEB_PROXY_PORT 15001
set_config WEB_PROXY_ALLOWED_HOSTS 'example.com,*.example.org,localhost,127.0.0.1'
upgrade_config
assert_eq '15001' "$(get_config SECURECONNECTION_WEB_PROXY_PORT)" 'upgrade must preserve a custom Web Proxy port'
assert_eq 'example.com,*.example.org,localhost,127.0.0.1' "$(get_config WEB_PROXY_ALLOWED_HOSTS)" 'upgrade must preserve a custom Web Proxy allowlist'
printf 'PASS: upgrade adds and preserves Web Proxy configuration\n'

(
  # a configuration written before the rename: the values move to the XPAM names, an explicit new name wins
  prepare_xpamctl() { :; }
  remove_config SECURECONNECTION_WEB_PROXY_PORT
  remove_config SECURECONNECTION_SSH_PORT
  remove_config AI_ENABLED
  set_config KOKO_WEB_PROXY_PORT 15003
  set_config KOKO_SSH_PORT 2223
  set_config KAEL_ENABLED 0
  set_config CHEN_ENABLED 0
  set_config WEBCONNECTOR_ENABLED 1
  set_config JUMPSERVER_COLOR_DEPTH 16
  migrate_config
  assert_eq '15003' "$(get_config SECURECONNECTION_WEB_PROXY_PORT)" 'the old Web Proxy port must move to the new name'
  assert_eq '2223' "$(get_config SECURECONNECTION_SSH_PORT)" 'the old SSH port must move to the new name'
  assert_eq '0' "$(get_config AI_ENABLED)" 'KAEL_ENABLED must move to AI_ENABLED'
  assert_eq '1' "$(get_config WEBCONNECTOR_ENABLED)" 'an explicit new name must win over the old one'
  assert_eq '16' "$(get_config XPAM_COLOR_DEPTH)" 'JUMPSERVER_* settings must move to XPAM_*'
  for old_key in KOKO_WEB_PROXY_PORT KOKO_SSH_PORT KAEL_ENABLED CHEN_ENABLED JUMPSERVER_COLOR_DEPTH; do
    assert_eq '' "$(get_config "${old_key}")" "the old setting ${old_key} must be removed after the move"
  done
  remove_config SECURECONNECTION_SSH_PORT
  remove_config XPAM_COLOR_DEPTH
  remove_config WEBCONNECTOR_ENABLED
  remove_config AI_ENABLED
)
printf 'PASS: upgrade moves settings named after upstream components to the XPAM names\n'

(
  docker_calls="${test_dir}/obsolete-docker-calls"
  mock_container_names=$'jms_lion\njms_facelive\njms_panda\njms_xrdp\njms_lion_backup\njms_core\njms_postgresql'
  fail_action=''
  docker() {
    printf '%s\n' "$*" >>"${docker_calls}"
    case "$1" in
      ps) printf '%s\n' "${mock_container_names}" ;;
      stop|rm) [[ "$*" != "${fail_action}" ]] ;;
      *) return 1 ;;
    esac
  }
  export USE_XPACK=1 XRDP_ENABLED=0
  remove_obsolete_containers
  expected_calls=$'ps -a --format {{.Names}}\nstop jms_lion\nrm jms_lion\nstop jms_facelive\nrm jms_facelive\nstop jms_panda\nrm jms_panda\nstop jms_xrdp\nrm jms_xrdp'
  assert_eq "${expected_calls}" "$(cat "${docker_calls}")" 'cleanup must remove only exact obsolete container names'

  mock_container_names=jms_xrdp
  XRDP_ENABLED=1
  : >"${docker_calls}"
  remove_obsolete_containers
  assert_eq 'ps -a --format {{.Names}}' "$(cat "${docker_calls}")" 'explicitly enabled enterprise XRDP must be preserved'
  USE_XPACK=0
  : >"${docker_calls}"
  remove_obsolete_containers
  assert_contains "$(cat "${docker_calls}")" 'rm jms_xrdp' 'XRDP must be removed outside the enterprise edition'

  mock_container_names=''
  : >"${docker_calls}"
  remove_obsolete_containers
  assert_eq 'ps -a --format {{.Names}}' "$(cat "${docker_calls}")" 'cleanup must succeed when obsolete containers are already absent'

  mock_container_names=jms_lion
  for fail_action in 'stop jms_lion' 'rm jms_lion'; do
    if remove_obsolete_containers; then
      fail "cleanup must propagate failure: ${fail_action}"
    fi
  done
  docker() { return 1; }
  if remove_obsolete_containers; then
    fail 'cleanup must propagate Docker listing failure'
  fi
)
printf 'PASS: upgrade cleans obsolete containers and preserves enabled XRDP\n'

current_version_under_test=v3.10.11
get_config() {
  if [[ "$1" == "CURRENT_VERSION" ]]; then
    printf '%s\n' "${current_version_under_test}"
  else
    printf '%s\n' "${2:-}"
  fi
}
log_error() { :; }
gettext() { printf '%s\n' "$1"; }

verify_upgrade_version
current_version_under_test=v3.10.10
if verify_upgrade_version; then
  fail 'versions below the minimum upgrade version must be rejected'
fi
current_version_under_test=''
if verify_upgrade_version; then
  fail 'an empty current version must be rejected'
fi
printf 'PASS: upgrade version preflight handles boundary values\n'

STATIC_ENV="${test_dir}/static.env"
printf 'export VERSION=old-version\n' >"${STATIC_ENV}"
VERSION=v4.0.0-ce
persist_installer_version
assert_eq 'export VERSION=v4.0.0-ce' "$(<"${STATIC_ENV}")" 'version persistence must be atomic and exact'
printf 'PASS: installer version persistence writes the final version\n'

test_volume_dir="${test_dir}/volume"
mkdir -p "${test_volume_dir}/video/data"
printf 'recording\n' >"${test_volume_dir}/video/data/sample"
get_config() {
  if [[ "$1" == "VOLUME_DIR" ]]; then
    printf '%s\n' "${test_volume_dir}"
  else
    printf '%s\n' "${2:-}"
  fi
}
migrate_data_folder
[[ -f "${test_volume_dir}/video-worker/data/sample" ]] || fail 'video-worker data was not migrated'
[[ -L "${test_volume_dir}/video" ]] || fail 'legacy video data path must remain as a rollback-compatible symlink'
printf 'PASS: video-worker data migration remains rollback compatible\n'
