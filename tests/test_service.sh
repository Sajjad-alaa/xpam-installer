#!/usr/bin/env bash

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

. "${TEST_ROOT}/scripts/gists/service.sh"

get_config() {
  case "$1" in
    DB_HOST) printf '%s\n' external-db ;;
    REDIS_HOST) printf '%s\n' external-redis ;;
    *) printf '%s\n' "${2:-}" ;;
  esac
}

create_db_ops_env() { return 0; }
secrets_from_vault() { return 1; }  # (service.sh calls it when composing the command; it lives in conf.sh)
docker() { return 1; }
log_error() { :; }
gettext() { printf '%s\n' "$1"; }

if perform_db_migrations; then
  fail 'perform_db_migrations must return failure when the migration command fails'
fi
printf 'PASS: migration failures return to the caller\n'

if wait_container_healthy xpam_missing 0 0; then
  fail 'health waits must time out when a container never becomes healthy'
fi
printf 'PASS: health waits have a bounded failure path\n'

TEST_USE_XPACK=1
TEST_VIDEO_WORKER_ENABLED=''
get_config_or_env() {
  case "$1" in
    USE_XPACK) printf '%s\n' "${TEST_USE_XPACK}" ;;
    VIDEO_WORKER_ENABLED) printf '%s\n' "${TEST_VIDEO_WORKER_ENABLED}" ;;
    *) printf '%s\n' "${2:-}" ;;
  esac
}
BUILD_ARCH=$(uname -m)
video_cmd=$(get_video_worker_cmd_line)
assert_contains "${video_cmd}" 'compose/video-worker.yml' 'video-worker command must use its compose file'
video_worker_can_start || fail 'enabled EE worker must be startable'

TEST_VIDEO_WORKER_ENABLED=0
if video_worker_can_start; then
  fail 'VIDEO_WORKER_ENABLED=0 must block direct worker start'
fi
TEST_VIDEO_WORKER_ENABLED=''
TEST_USE_XPACK=0
if video_worker_can_start; then
  fail 'CE worker must not be startable'
fi
TEST_USE_XPACK=1

printf 'PASS: video-worker uses one name for its service and compose file\n'

get_config() {
  case "$1" in
    DB_HOST) printf 'postgresql\n' ;;
    REDIS_HOST) printf 'redis\n' ;;
    HA_MODE|REDIS_EXPOSE_PORT|USE_IPV6) printf '%s\n' "${2:-}" ;;
    *) printf '%s\n' "${2:-}" ;;
  esac
}
get_db_info() { printf 'compose/postgresql.yml -f compose/postgresql.port.yml\n'; }
db_only_cmd=$(get_db_compose_cmd db)
assert_contains "${db_only_cmd}" 'compose/postgresql.yml' 'db target must include the database compose file'
if [[ "${db_only_cmd}" == *'compose/redis.yml'* ]]; then
  fail 'db target must not include the Redis compose file'
fi
redis_only_cmd=$(get_db_compose_cmd redis)
assert_contains "${redis_only_cmd}" 'compose/redis.yml' 'redis target must include the Redis compose file'
if [[ "${redis_only_cmd}" == *'compose/postgresql.yml'* ]]; then
  fail 'redis target must not include the database compose file'
fi
printf 'PASS: database management targets remain scoped\n'

docker_calls=()
docker() {
  if [[ "$1" == 'ps' ]]; then
    printf 'old-video-worker-id\n'
    return 0
  fi
  docker_calls+=("$*")
  return 0
}
TEST_VIDEO_WORKER_ENABLED=0
stop_disabled_video_worker
assert_eq 'container rm -f old-video-worker-id' "${docker_calls[0]}" 'disabled worker must remove the stale Compose container'
TEST_VIDEO_WORKER_ENABLED=''
docker_calls=()
stop_disabled_video_worker
assert_eq '0' "${#docker_calls[@]}" 'enabled worker must not be removed'
TEST_USE_XPACK=0
stop_disabled_video_worker
assert_eq 'container rm -f old-video-worker-id' "${docker_calls[0]}" 'CE mode must remove a stale worker container'
TEST_USE_XPACK=1
docker_calls=()
printf 'PASS: disabling video-worker removes only the stale container\n'

# containers created under the service names used before the rename (koko, chen, kael) are removed so compose
# can create them again under the new names; a container already under its new name is left alone
docker_calls=()
docker() {
  if [[ "$1" == 'ps' ]]; then
    local args="$*"
    [[ "${args}" == *'com.docker.compose.service=koko'* || "${args}" == *'com.docker.compose.service=kael'* ]] && printf 'old-%s-id\n' "${args##*=}"
    return 0
  fi
  docker_calls+=("$*")
  return 0
}
remove_renamed_service_containers >/dev/null
assert_eq '2' "${#docker_calls[@]}" 'only the containers under an old service name must be removed'
assert_eq 'container rm -f old-koko-id' "${docker_calls[0]}" 'the secure connection container under its old service name must be removed'
assert_eq 'container rm -f old-kael-id' "${docker_calls[1]}" 'the AI container under its old service name must be removed'
docker() {
  [[ "$1" == 'ps' ]] && return 0
  docker_calls+=("$*")
  return 0
}
docker_calls=()
remove_renamed_service_containers >/dev/null
assert_eq '0' "${#docker_calls[@]}" 'nothing must be removed once the containers carry the new service names'
docker() { [[ "$1" == 'ps' ]] && return 1; return 0; }
if remove_renamed_service_containers >/dev/null 2>&1; then
  fail 'a failed docker ps must stop the start (no half-renamed stack)'
fi
printf 'PASS: containers under the old service names are recreated under the new ones\n'

grep -q 'remove_renamed_service_containers || return 1' "${TEST_ROOT}/xpamctl.sh" \
  && [[ $(grep -c 'remove_renamed_service_containers || return 1' "${TEST_ROOT}/xpamctl.sh") -ge 3 ]] \
  || fail 'start and both full stops must remove the containers of renamed services'
grep -q 'remove_renamed_service_containers || return 1' "${TEST_ROOT}/scripts/ha.sh" \
  || fail 'the HA app stop (upgrade) must remove the containers of renamed services'
grep -q "python ./xpam upgrade_db" "${TEST_ROOT}/scripts/gists/service.sh" \
  || fail 'the database migration must call the xpam launcher'
printf 'PASS: stops and the database migration handle the renamed services and launcher\n'

docker_calls=()
docker() {
  if [[ "$1" == 'ps' ]]; then
    printf 'old-video-worker-id\n'
    return 0
  fi
  docker_calls+=("$*")
  return 0
}
remove_stopped_openbao_init_container
assert_eq 'container rm xpam_openbao_init' "${docker_calls[0]}" 'completed OpenBao init container must be removed'
printf 'PASS: completed OpenBao initializer is removed after startup\n'
