#!/usr/bin/env bash

function get_db_images() {
  get_db_info "image"
}

function reuse_legacy_db_image() {
  local image=$1

  # New offline packages only bundle PostgreSQL. Existing MySQL/MariaDB
  # installations retain their database image, including legacy tags.
  case "${image}" in
    mysql:8.0|mariadb:10.6) ;;
    *) return 1 ;;
  esac
  if docker image inspect "${image}" &>/dev/null; then
    return 0
  fi
  if docker image inspect "jumpserver/${image}" &>/dev/null; then
    docker tag "jumpserver/${image}" "${image}"
    return $?
  fi
  return 1
}

function get_image_namespace() {
  local namespace

  namespace=$(get_config_or_env NAMESPACE jumpserver)
  namespace=${namespace%/}
  echo "${namespace:-jumpserver}"
}

# XPAM: these services run XPAM-built images instead of the upstream JumpServer ones.
function get_xpam_image_name() {
  case "$1" in
    core) echo "core" ;;
    web) echo "web" ;;
    gateway) echo "gateway" ;;
    workspace) echo "workspace" ;;
    koko) echo "secureconnection" ;;
    chen) echo "webconnector" ;;
    kael) echo "ai" ;;
    facelive) echo "facelive" ;;
    browser) echo "browser" ;;
    *) return 1 ;;
  esac
}

function get_xpam_namespace() {
  local namespace

  namespace=$(get_config_or_env XPAM_NAMESPACE xpam)
  namespace=${namespace%/}
  echo "${namespace:-xpam}"
}

function get_xpam_version() {
  local version

  version=$(get_config_or_env XPAM_VERSION)
  echo "${version:-${XPAM_DEFAULT_VERSION:-v5.1.25}}"
}

# Registry holding the XPAM images as <registry>/<name>:<tag>. The default comes from static.env
# (XPAM_DEFAULT_IMAGE_REGISTRY); XPAM_IMAGE_REGISTRY in config.txt overrides it.
# XPAM_IMAGE_REGISTRY=local means "never pull": the images must already exist on this server
# (built here, or loaded from the offline package). They are never pulled from Docker Hub, where
# the "xpam" namespace belongs to someone else.
function get_xpam_image_registry() {
  local registry

  registry=$(get_config_or_env XPAM_IMAGE_REGISTRY)
  case "${registry}" in
    local | none | off | -)
      echo ""
      return 0
      ;;
    "") registry=${XPAM_DEFAULT_IMAGE_REGISTRY:-} ;;
  esac
  echo "${registry%/}"
}

# ghcr.io/owner/xpam -> ghcr.io
function get_xpam_registry_host() {
  local registry

  registry=$(get_xpam_image_registry)
  echo "${registry%%/*}"
}

# ghcr.io/owner/xpam -> owner (the account that usually signs in)
function get_xpam_registry_owner() {
  local registry rest

  registry=$(get_xpam_image_registry)
  rest=${registry#*/}
  [[ "${rest}" != "${registry}" ]] || return 0
  echo "${rest%%/*}"
}

function print_xpam_registry_login_help() {
  local host=$1 owner=$2

  echo "  The XPAM images are private. Sign in to ${host} once on this server:" >&2
  echo "      docker login ${host} -u ${owner:-<github-user>}" >&2
  echo "  As the password use a GitHub personal access token (classic) with the read:packages scope" >&2
  echo "  (GitHub -> Settings -> Developer settings -> Personal access tokens)." >&2
  echo "  Then run the same xpamctl command again; it continues where it stopped." >&2
}

# Checks, before anything is downloaded, that this server may read the XPAM images. When it may
# not, a person at the terminal is asked to sign in; an unattended run can pass
# XPAM_REGISTRY_USER and XPAM_REGISTRY_TOKEN in the environment (they are not stored by XPAM).
function ensure_xpam_registry_access() {
  local registry host owner probe output user attempt

  registry=$(get_xpam_image_registry)
  [[ -n "${registry}" ]] || return 0
  host=$(get_xpam_registry_host)
  owner=$(get_xpam_registry_owner)
  probe="${registry}/$(get_xpam_image_name gateway):$(get_xpam_version)"

  for attempt in 1 2 3 4; do
    if output=$(docker manifest inspect "${probe}" 2>&1); then
      return 0
    fi
    if ! echo "${output}" | grep -qiE 'denied|unauthorized|authentication required|no basic auth|401|403'; then
      # Not a sign-in problem (no connection, plain-HTTP mirror, ...): the downloads that follow
      # report the precise reason, so do not stop here.
      return 0
    fi
    if [[ "${attempt}" == "4" ]]; then
      break
    fi

    if [[ "${attempt}" == "1" && -n "${XPAM_REGISTRY_TOKEN:-}" ]]; then
      echo "Signing in to ${host} as ${XPAM_REGISTRY_USER:-${owner}}"
      if ! printf '%s' "${XPAM_REGISTRY_TOKEN}" |
        docker login "${host}" -u "${XPAM_REGISTRY_USER:-${owner}}" --password-stdin >/dev/null 2>&1; then
        log_error "Sign-in to ${host} with XPAM_REGISTRY_TOKEN failed"
      fi
      continue
    fi

    if [[ "${AUTO_INSTALL:-}" == "1" || ! -t 0 ]]; then
      break
    fi
    echo
    echo "The XPAM images are private: this server has to sign in to ${host} once."
    echo "Password = a GitHub personal access token (classic) with the read:packages scope."
    user="${owner}"
    read_from_input user "GitHub user name" "" "${owner}"
    if ! docker login "${host}" -u "${user}"; then
      echo_red "Sign-in failed, try again"
    fi
  done

  log_error "This server is not allowed to download the XPAM images from ${registry}" >&2
  print_xpam_registry_login_help "${host}" "${owner}"
  return 1
}

function get_image_pull_prefix() {
  local image_pull_prefix registry

  image_pull_prefix=$(get_config_or_env IMAGE_PULL_PREFIX)
  if [[ -n "${image_pull_prefix}" ]]; then
    echo "${image_pull_prefix%/}"
    return 0
  fi

  # Compatibility for existing CI jobs. REGISTRY historically meant the
  # registry root containing the jumpserver namespace.
  registry=$(get_config_or_env REGISTRY)
  if [[ -n "${registry}" ]]; then
    echo "${registry%/}/jumpserver"
  fi
}

function emit_image_mapping() {
  local source_image=$1 target_image=$2 exact_source=${3:-0}

  printf '%s\t%s\t%s\n' "${source_image}" "${target_image}" "${exact_source}"
}

function get_image_mappings() {
  local use_xpack enabled_services service image db_image namespace
  local xpam_name xpam_namespace xpam_version xpam_registry

  use_xpack=$(get_config_or_env USE_XPACK)
  namespace=$(get_image_namespace)
  xpam_namespace=$(get_xpam_namespace)
  xpam_version=$(get_xpam_version)
  xpam_registry=$(get_xpam_image_registry)
  emit_image_mapping "redis:7.4.10-bookworm" "redis:7.4.10-bookworm"
  db_image=$(get_db_images)
  if [[ -n "${db_image}" ]]; then
    emit_image_mapping "${db_image}" "${db_image}"
  fi
  if is_ha_enabled; then
    emit_image_mapping "gcr.io/etcd-development/etcd:v3.5.21" "gcr.io/etcd-development/etcd:v3.5.21"
    # XPAM high availability: PostgreSQL under Patroni is an XPAM image
    if [[ -n "${xpam_registry}" ]]; then
      emit_image_mapping "${xpam_registry}/postgresql-ha:${xpam_version}" "${xpam_namespace}/postgresql-ha:${xpam_version}" 1
    else
      emit_image_mapping "${xpam_namespace}/postgresql-ha:${xpam_version}" "${xpam_namespace}/postgresql-ha:${xpam_version}" 2
    fi
  fi

  enabled_services=${OFFLINE_IMAGE_SERVICES:-$(get_enabled_services)}
  enabled_services=${enabled_services//,/ }

  for service in ${enabled_services}; do
    case "${service}" in
      "" | worker | celery | jdmc | panda)
        ;;
      core | web | gateway | workspace | koko | chen | kael | facelive | browser)
        xpam_name=$(get_xpam_image_name "${service}")
        if [[ -n "${xpam_registry}" ]]; then
          emit_image_mapping \
            "${xpam_registry}/${xpam_name}:${xpam_version}" \
            "${xpam_namespace}/${xpam_name}:${xpam_version}" 1
        else
          emit_image_mapping \
            "${xpam_namespace}/${xpam_name}:${xpam_version}" \
            "${xpam_namespace}/${xpam_name}:${xpam_version}" 2
        fi
        ;;
      *)
        emit_image_mapping \
          "jumpserver/${service}:${VERSION}" \
          "${namespace}/${service}:${VERSION}"
        ;;
    esac
  done

  if [[ "${use_xpack}" == "1" ]]; then
    # Panda is distributed to Linux publishers; it is not a local Compose service.
    if [[ "${INCLUDE_PANDA_IMAGE:-0}" == "1" ]]; then
      emit_image_mapping "jumpserver/panda:${VERSION}" "${namespace}/panda:${VERSION}"
    fi
    emit_image_mapping \
      "jumpserver/ansible-executor:latest" \
      "${namespace}/ansible-executor:latest"
  fi
  if should_include_openbao_image; then
    image=$(get_openbao_image)
    emit_image_mapping "${image}" "${image}"
  fi
  if should_include_jdmc_image; then
    emit_image_mapping \
      "jumpserver/jdmc:${VERSION}" \
      "${namespace}/jdmc:${VERSION}"
  fi
}

function get_pull_images() {
  local source_image target_image exact_source
  local -a images=()

  while IFS=$'\t' read -r source_image target_image exact_source; do
    [[ -n "${source_image}" ]] && images+=("${source_image}")
  done < <(get_image_mappings)

  echo "${images[@]}"
}

function get_images() {
  local source_image target_image exact_source
  local -a images=()

  while IFS=$'\t' read -r source_image target_image exact_source; do
    [[ -n "${target_image}" ]] && images+=("${target_image}")
  done < <(get_image_mappings)

  echo "${images[@]}"
}

function get_offline_image_manifest() {
  local source_image target_image exact_source resolved_source
  local INCLUDE_PANDA_IMAGE=${INCLUDE_PANDA_IMAGE:-1}

  while IFS=$'\t' read -r source_image target_image exact_source; do
    [[ -n "${source_image}" && -n "${target_image}" ]] || continue
    if [[ "${exact_source}" == "1" || "${exact_source}" == "2" ]]; then
      resolved_source=${source_image}
    else
      resolved_source=$(get_image_full_path "${source_image}")
    fi
    # Third column: 2 = local-only XPAM image (never pulled), otherwise an exact pull source.
    if [[ "${exact_source}" == "2" ]]; then
      printf '%s\t%s\t2\n' "${resolved_source}" "${target_image}"
    else
      printf '%s\t%s\n' "${resolved_source}" "${target_image}"
    fi
  done < <(get_image_mappings)
}

function image_has_prefix() {
  case "$1" in
    jumpserver/*) echo "1" ;;
    *) echo "0" ;;
  esac
}

function image_uses_mirror_prefix() {
  image=$1

  # Infrastructure images are pulled directly from Docker Hub. Only
  # JumpServer application images and the remaining third-party images use
  # the configured internal mirror.
  case "${image}" in
    redis|redis:*|redis@*|postgres|postgres:*|postgres@*|openbao|openbao:*|openbao@*|openbao/openbao|openbao/openbao:*|openbao/openbao@*)
      echo "0"
      return
      ;;
  esac

  if [[ "${image}" != */* || $(image_has_prefix "${image}") == "1" ]]; then
    echo "1"
  else
    echo "0"
  fi
}

function image_is_registry_qualified() {
  local image=$1 first_component

  [[ "${image}" == */* ]] || return 1
  first_component=${image%%/*}
  [[ "${first_component}" == "localhost" ||
    "${first_component}" == *.* ||
    "${first_component}" == *:* ]]
}

function check_image_exists() {
  image=$1
  if docker image inspect -f '{{ .Id }}' "$image" &>/dev/null; then
    echo "1"
  else
    echo "0"
  fi
}

function get_image_full_path() {
  local image=$1 image_pull_prefix image_pull_scope
  local docker_image_mirror docker_image_prefix
  local full_image_path app

  if image_is_registry_qualified "${image}"; then
    echo "${image}"
    return 0
  fi

  image_pull_prefix=$(get_image_pull_prefix)
  image_pull_scope=$(get_config_or_env IMAGE_PULL_SCOPE jumpserver)
  if [[ -n "${image_pull_prefix}" ]]; then
    if [[ "${image_pull_scope}" == "all" || $(image_has_prefix "${image}") == "1" ]]; then
      app=${image##*/}
      echo "${image_pull_prefix}/${app}"
    else
      # Infrastructure images retain their own registry and namespace.
      echo "${image}"
    fi
    return 0
  fi

  # Compatibility with the previous mirror configuration.
  docker_image_mirror=$(get_config_or_env DOCKER_IMAGE_MIRROR)
  docker_image_prefix=$(get_config_or_env DOCKER_IMAGE_PREFIX)
  if [[ "${docker_image_mirror}" == "1" ]]; then
    if [[ -z "${docker_image_prefix}" ]]; then
      echo "DOCKER_IMAGE_MIRROR=1 needs DOCKER_IMAGE_PREFIX (there is no built-in mirror)" >&2
    fi
  fi

  full_image_path="${image}"
  if [[ -n "${docker_image_prefix}" ]]; then
    if [[ $(image_uses_mirror_prefix "${image}") != "1" ]]; then
      full_image_path="${image}"
    elif echo "${docker_image_prefix}" | grep -q "/";then
      app=${image##*/}
      full_image_path="${docker_image_prefix%/}/${app}"
    elif [[ $(image_has_prefix "${image}") != "1" ]]; then
      full_image_path="${docker_image_prefix}/jumpserver/${image}"
    else
      full_image_path="${docker_image_prefix}/${image}"
    fi
  fi

  echo "${full_image_path}"
}

function pull_image() {
  local image=$1 requested_target=${2:-} exact_source=${3:-0}
  local full_image_path pull_args to_image image_pull_policy namespace xpam_registry pull_output

  if [[ "${exact_source}" == "2" ]]; then
    if [[ "$(check_image_exists "${image}")" == "1" ]]; then
      echo "[${image}] XPAM image present"
      return 0
    fi
    echo "[${image}] XPAM image not found on this server. XPAM_IMAGE_REGISTRY=local is set in" \
      "config.txt: build the image here, load the offline package, or remove that line to download it" >&2
    return 1
  fi

  if [[ "${exact_source}" == "1" ]]; then
    full_image_path="${image}"
  else
    full_image_path=$(get_image_full_path "${image}")
  fi
  image_pull_policy=$(get_config_or_env 'IMAGE_PULL_POLICY')

  pull_args=""
  case "${BUILD_ARCH:-}" in
    "x86_64") pull_args="--platform linux/amd64" ;;
    "aarch64") pull_args="--platform linux/arm64" ;;
    "loongarch64") pull_args="--platform linux/loong64" ;;
    "s390x") pull_args="--platform linux/s390x" ;;
  esac

  if [[ -n "${requested_target}" ]]; then
    to_image="${requested_target}"
  else
    to_image="${image}"
  fi
  if [[ -z "${requested_target}" && "${to_image}" == jumpserver/* ]]; then
    namespace=$(get_image_namespace)
    to_image="${namespace}/${to_image#jumpserver/}"
  fi
  # XPAM images keep the same tag across rebuilds, so a copy that is already on the server may be
  # an older build: always ask the registry (a pull of an up-to-date image downloads nothing).
  xpam_registry=$(get_xpam_image_registry)
  if [[ -n "${xpam_registry}" && "${full_image_path}" == "${xpam_registry}/"* ]]; then
    image_pull_policy=Always
  fi
  if [[ "$(check_image_exists "${full_image_path}")" != "1" || "${image_pull_policy}" == "Always" ]]; then
    if ! pull_output=$(docker pull -q ${pull_args} "${full_image_path}" 2>&1); then
      echo "[${to_image}] download failed from ${full_image_path}" >&2
      echo "${pull_output}" | tail -n 2 | sed 's/^/    /' >&2
      return 1
    fi
  fi

  if [[ "${full_image_path}" != "${to_image}" ]]; then
    if ! docker tag "${full_image_path}" "${to_image}"; then
      echo "[${to_image}] tag failed: ${full_image_path} -> ${to_image}" >&2
      return 1
    fi
  fi
  echo "[${to_image}] ready"
  return 0
}


function pull_images() {
  local source_image target_image exact_source pid
  local INCLUDE_PANDA_IMAGE=${INCLUDE_PANDA_IMAGE:-0}
  local pull_failed=0
  local -a pids=()

  ensure_xpam_registry_access || return 1
  if [[ -n "$(get_xpam_image_registry)" ]]; then
    echo "Downloading the images (several GB on a first install; this can take a while) ..."
  else
    echo "Checking the images on this server ..."
  fi

  trap 'kill ${pids[*]}' SIGINT SIGTERM

  while IFS=$'\t' read -r source_image target_image exact_source; do
    [[ -n "${source_image}" && -n "${target_image}" ]] || continue
    pull_image "${source_image}" "${target_image}" "${exact_source:-1}" &
    pids+=("$!")
  done < <(get_offline_image_manifest)
  for pid in "${pids[@]}"; do
    if ! wait "${pid}"; then
      pull_failed=1
    fi
  done

  trap - SIGINT SIGTERM
  if [[ "${pull_failed}" != "0" ]]; then
    log_error "Some images could not be downloaded. Fix the problem above and run the same command again."
  fi
  return "${pull_failed}"
}

function prepare_virtualapp_resources() {
  local panda_image panda_filename volume_dir

  [[ "$(get_config_or_env USE_XPACK)" == "1" ]] || return 0
  panda_image="$(get_image_namespace)/panda:${VERSION}"

  panda_filename="${panda_image##*/}.zst"
  if [[ ! -f "${SCRIPT_DIR}/images/${panda_filename}" &&
    ! -f "${SCRIPT_DIR}/images/${panda_filename/:/_}" &&
    ! -f "${SCRIPT_DIR}/docker/docker.tar.gz" ]]; then
    return 0
  fi

  volume_dir=$(get_config VOLUME_DIR)
  if [[ -z "${volume_dir}" ]]; then
    log_error "VOLUME_DIR is required for virtual app resources"
    return 1
  fi
  bash "${SCRIPT_DIR}/virtualapp_resources.sh" \
    "${SCRIPT_DIR}/images" "${SCRIPT_DIR}/docker/docker.tar.gz" \
    "${volume_dir}/core/data/virtualapp" "${panda_image}" \
    "${DOCKER_VERSION}" "${DOCKER_BIN_SHA256:-}"
}
