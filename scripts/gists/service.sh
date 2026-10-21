
common_services=(core kael worker koko chen gateway web workspace browser)
xpack_services=(magnus razor xrdp video-worker nec)


function get_enabled_services() {
  enabled_services=()

  use_xpack=$(get_config_or_env USE_XPACK)
  services=("${common_services[@]}")
  if [[ "${use_xpack}" == "1" ]]; then
    services+=("${xpack_services[@]}")
  fi

  for service in "${services[@]}"; do
    key=$(echo "$service" | tr '[:lower:]' '[:upper:]')
    key="${key}_ENABLED"
    key=$(echo "$key" | sed 's/-/_/g')
    # The worker was the "celery" service before the rename: honour CELERY_ENABLED=0 too
    if [[ "${service}" == "worker" && "$(get_config_or_env CELERY_ENABLED)" == "0" ]]; then
      continue
    fi
    if [[ "$(get_config_or_env "${key}")" != "0" ]]; then
      enabled_services+=("${service}")
    fi
  done
 
  echo "${enabled_services[@]}"
}


function check_volume_dir() {
  volume_dir=$(get_config VOLUME_DIR)
  if [[ -d "${volume_dir}" ]]; then
    echo "1"
  else
    echo "0"
  fi
}

function check_db_data() {
  db_type=$1
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    return
  fi
  volume_dir=$(get_config VOLUME_DIR)
  if [[ -d "${volume_dir}/${db_type}/data" ]]; then
    echo "1"
  else
    echo "0"
  fi
}

function get_db_images_file() {
  get_db_info "file"
}

# XPAM: high availability (two servers + a witness, see scripts/ha.sh)
function is_ha_enabled() {
  [[ "$(get_config HA_ENABLED)" == "1" ]]
}

function get_db_info() {
  info_type=$1
  db_engine=$(get_config DB_ENGINE "mysql")
  db_host=$(get_config DB_HOST)
  check_volume_dir=$(check_volume_dir)

  if [[ "${check_volume_dir}" == "0" ]]; then
    db_engine=$(get_config DB_ENGINE "postgresql")
  fi

  mysql_data_exists="0"
  mariadb_data_exists="0"
  postgres_data_exists="0"

  case "${db_engine}" in
    "mysql")
      if [[ "${db_host}" == "mysql" ]]; then
        mysql_data_exists=$(check_db_data "mysql")
      fi
      mariadb_data_exists="1"
      ;;
    "postgresql")
      postgres_data_exists="1"
      ;;
  esac

  case "${info_type}" in
    "image")
      if [[ "${mysql_data_exists}" == "1" ]]; then
        echo "mysql:8.0"
      elif [[ "${mariadb_data_exists}" == "1" ]]; then
        echo "mariadb:10.6"
      elif [[ "${postgres_data_exists}" == "1" ]]; then
        # (also in high availability: backups run pg_dump from this image)
        echo "postgres:16.15-bookworm"
      fi
      ;;
    "file")
      if [[ "${mysql_data_exists}" == "1" ]]; then
        echo "compose/mysql.yml -f compose/mysql.port.yml"
      elif [[ "${mariadb_data_exists}" == "1" ]]; then
        echo "compose/mariadb.yml -f compose/mysql.port.yml"
      elif [[ "${postgres_data_exists}" == "1" ]]; then
        if is_ha_enabled; then
          echo "compose/ha-postgresql.yml -f compose/ha-etcd.yml"
        else
          echo "compose/postgresql.yml -f compose/postgresql.port.yml"
        fi
      fi
      ;;
    *)
      exit 1 ;;
  esac
}


function get_docker_compose_services() {
  ignore_db=${1-}
  db_engine=$(get_config DB_ENGINE "mysql")
  db_host=$(get_config DB_HOST)
  redis_host=$(get_config REDIS_HOST)
  redis_expose_port=$(get_config REDIS_EXPOSE_PORT)
  use_es=$(get_config USE_ES)
  use_minio=$(get_config USE_MINIO)
  use_loki=$(get_config USE_LOKI)
  ha_mode=$(get_config HA_MODE)
  use_xpack=$(get_config_or_env USE_XPACK)
  services=$(get_enabled_services)

  if [[ "${ignore_db}" != "ignore_db" ]]; then
    info=(get_db_info)
    case "${db_engine}" in
      mysql)
        [[ "${db_host}" == "mysql" || "${ha_mode}" == "1" ]] && services+=" mysql"
        ;;
      postgresql)
        [[ "${db_host}" == "postgresql" || "${ha_mode}" == "1" ]] && services+=" postgresql"
        ;;
    esac
    [[ "${redis_host}" == "redis" || "${ha_mode}" == "1" || -n "${redis_expose_port}" ]] && services+=" redis"
  fi

  [[ "${use_es}" == "1" ]] && services+=" es"
  [[ "${use_minio}" == "1" ]] && services+=" minio"
  [[ "${use_loki}" == "1" ]] && services+=" loki"
  if is_internal_openbao_enabled; then
    services+=" openbao"
  fi

  echo "${services}"
}

function get_docker_compose_cmd_line() {
  ignore_db=${1-}
  use_ipv6=$(get_config USE_IPV6)
  https_port=$(get_config HTTPS_PORT)
  http_port=$(get_config HTTP_PORT)
  cap_addon=$(get_config CAP_ADDON)

  cmd="docker compose"
  if [[ "${use_ipv6}" != "1" ]]; then
    cmd+=" -f compose/network.yml"
  else
    cmd+=" -f compose/network-v6.yml"
  fi
  services=$(get_docker_compose_services "ignore_db")

  for service in $services; do
      cmd+=" -f compose/${service}.yml"
  done

  if [[ "${ignore_db}" != "ignore_db" ]]; then
    db_yml=$(get_db_compose_yml)
    if [[ -n "${db_yml}" ]]; then
      cmd+=" ${db_yml}"
    fi
  fi

  if [[ -n "${https_port}" && "${https_port}" != "0" ]]; then
    cmd+=" -f compose/gateway.https.yml"
  fi

  if [[ -n "${http_port}" && "${http_port}" != "0" ]]; then
    cmd+=" -f compose/gateway.http.yml"
  fi

  if [[ "${cap_addon}" == "1" ]]; then
    cmd+=" -f compose/cap_addon.yml"
  fi

  echo "${cmd}"
}

function get_video_worker_cmd_line() {
  use_xpack=$(get_config_or_env USE_XPACK)
  if [[ "${use_xpack}" != "1" ]]; then
    return
  fi
  use_ipv6=$(get_config USE_IPV6)
  cmd="docker compose"
  if [[ "${use_ipv6}" != "1" ]]; then
    cmd+=" -f compose/network.yml"
  else
    cmd+=" -f compose/network-v6.yml"
  fi
  cmd+=" -f compose/video-worker.yml"
  echo "${cmd}"
}

function video_worker_can_start() {
  [[ "$(get_config_or_env USE_XPACK)" == "1" && \
     "$(get_config_or_env VIDEO_WORKER_ENABLED)" != "0" ]]
}

function stop_disabled_video_worker() {
  local container_id
  video_worker_can_start && return 0

  # Compose does not remove services omitted from a later `up -d`. Remove only
  # this installer's old video-worker container; keep its bind-mounted data.
  container_id=$(docker ps -a -q \
    --filter 'name=^/xpam_video-worker$' \
    --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME:-xpam}" \
    --filter 'label=com.docker.compose.service=video-worker') || return 1
  if [[ -n "${container_id}" ]]; then
    docker container rm -f "${container_id}" >/dev/null || return 1
  fi
}

function prepare_video_worker_volume() {
  local volume_dir data_dir image user_spec owner
  if ! video_worker_can_start; then
    return 0
  fi

  volume_dir=$(get_config VOLUME_DIR)
  data_dir="${volume_dir}/video-worker/data"
  mkdir -p "${data_dir}" || return 1

  image="$(get_image_namespace)/video-worker:${VERSION}"
  user_spec=$(docker image inspect -f '{{.Config.User}}' "${image}") || {
    log_error "Unable to inspect video-worker image user: ${image}"
    return 1
  }
  if [[ "${user_spec}" =~ ^[0-9]+:[0-9]+$ ]]; then
    owner=${user_spec}
  else
    owner=$(docker run --rm --entrypoint /bin/sh "${image}" -c \
      'printf "%s:%s\n" "$(id -u)" "$(id -g)"') || {
      log_error "Unable to resolve video-worker image user: ${image}"
      return 1
    }
  fi
  if [[ ! "${owner}" =~ ^[0-9]+:[0-9]+$ ]]; then
    log_error "Invalid video-worker image user: ${owner}"
    return 1
  fi

  # Docker creates a missing bind-mount source as root. Match the directory to
  # the actual image user so image UID/GID changes do not break persistence.
  if [[ "$(stat -c '%u:%g' "${data_dir}")" != "${owner}" ]]; then
    chown -R "${owner}" "${data_dir}" || return 1
  fi
}


function remove_stopped_openbao_init_container() {
  # openbao-init is a one-shot dependency. Remove its completed container so it
  # does not remain in `docker ps -a`; a still-running initializer is preserved.
  docker container rm xpam_openbao_init &>/dev/null || true
}


# XPAM: containers used to be named jms_* in the Compose project "jms". Remove those old
# containers and their network once, so the renamed ones can start. Data is kept: it lives in
# bind-mounted folders, not in the containers.
function retire_legacy_project() {
  local container_ids network_ids

  container_ids=$(docker ps -aq --filter "label=com.docker.compose.project=jms") || return 1
  if [[ -n "${container_ids}" ]]; then
    echo "Replacing the old jms_* containers with xpam_* ones"
    # shellcheck disable=SC2086
    docker rm -f ${container_ids} >/dev/null || return 1
  fi
  network_ids=$(docker network ls -q --filter "label=com.docker.compose.project=jms") || return 1
  if [[ -n "${network_ids}" ]]; then
    # shellcheck disable=SC2086
    docker network rm ${network_ids} >/dev/null || return 1
  fi
}

# XPAM: before the gateway split, xpam_web was also the front door and published the HTTP/HTTPS
# ports. Remove that container once, so xpam_gateway can take the ports over.
# XPAM: the worker's Compose service was called "celery". Its container must go before the
# renamed service can create xpam_worker again.
function retire_renamed_services() {
  local container_ids

  container_ids=$(docker ps -aq \
    --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME:-xpam}" \
    --filter "label=com.docker.compose.service=celery") || return 1
  if [[ -n "${container_ids}" ]]; then
    # shellcheck disable=SC2086
    docker rm -f ${container_ids} >/dev/null || return 1
  fi
}

function retire_combined_web() {
  local published

  published=$(docker inspect -f '{{len .HostConfig.PortBindings}}' xpam_web 2>/dev/null) || return 0
  if [[ -n "${published}" && "${published}" != "0" ]]; then
    echo "Replacing the combined xpam_web container with xpam_gateway, xpam_web and xpam_workspace"
    docker rm -f xpam_web >/dev/null || return 1
  fi
}

# Number of installer updates published but not yet on this server ("" when it cannot be checked)
function get_pending_installer_updates() {
  [[ -d "${PROJECT_DIR}/.git" ]] && command -v git &>/dev/null || return 0
  GIT_TERMINAL_PROMPT=0 timeout 60 git -C "${PROJECT_DIR}" fetch --quiet 2>/dev/null || return 0
  git -C "${PROJECT_DIR}" rev-list --count 'HEAD..@{upstream}' 2>/dev/null
}

function get_db_compose_yml() {
  target=${1:-"all"}
  db_host=$(get_config DB_HOST)
  redis_host=$(get_config REDIS_HOST)
  ha_mode=$(get_config HA_MODE)
  db_images_file=$(get_db_info "file")
  redis_expose_port=$(get_config REDIS_EXPOSE_PORT)

  if [[ -z "${target}" ]]; then
    target="all"
  fi

  cmd=""
  if [[ "${target}" == "all" || "${target}" == "db" ]]; then
      if [[ "${db_host}" == "mysql" || "${db_host}" == "postgresql" || "${ha_mode}" == "1" ]]; then
        db_images_file=$(get_db_images_file)
        cmd+=" -f ${db_images_file}"
      fi
  fi
  if [[ "${target}" == "all" || "${target}" == "redis" ]]; then
    if [[ "${redis_host}" == "redis" || "${ha_mode}" == "1" || -n "${redis_expose_port}" ]]; then
      cmd+=" -f compose/redis.yml"
      if is_ha_enabled; then
        cmd+=" -f compose/ha-redis.yml"
      elif [[ -n "${redis_expose_port}" ]]; then
        cmd+=" -f compose/redis.port.yml"
      fi
    fi
  fi
  echo "${cmd}"
}


function get_db_compose_cmd() {
  target=${1:-"all"}
  use_ipv6=$(get_config USE_IPV6)
  use_xpack=$(get_config_or_env USE_XPACK)

  cmd="docker compose "
  yml=$(get_db_compose_yml "${target}")

  if [[ -n "${yml}" ]]; then
    cmd+=" ${yml}"
  fi
 
  if [[ "${use_ipv6}" != "1" ]]; then
    cmd+=" -f compose/network.yml"
  else
    cmd+=" -f compose/network-v6.yml"
  fi
  echo "$cmd"
}

function get_db_migrate_compose_cmd() {
  cmd=$(get_db_compose_cmd "all")
  cmd+=" -f compose/init-db.yml"
  echo "$cmd"
}

function create_db_ops_env() {
  retire_legacy_project || return 1
  cmd=$(get_db_migrate_compose_cmd)
  ${cmd} up -d || {
    return 1
  }
}

function down_db_ops_env() {
  docker stop xpam_core &>/dev/null
  docker rm xpam_core &>/dev/null
}

function db_redis_start() {
  target=$1
  retire_legacy_project || return 1
  cmd=$(get_db_compose_cmd "${target}")
  ${cmd} up -d || {
    return 1
  }
}

function db_redis_stop() {
  target=$1
  cmd=$(get_db_compose_cmd "${target}")
  ${cmd} down
}

function db_redis_restart() {
  local target=$1
  db_redis_stop "${target}" || return 1
  sleep 3
  db_redis_start "${target}"
}

function wait_container_healthy() {
  local container=$1
  local timeout=${2:-$(get_config CONTAINER_HEALTH_TIMEOUT 300)}
  local interval=${3:-5}
  local deadline status

  [[ "${timeout}" =~ ^[0-9]+$ ]] || timeout=300
  [[ "${interval}" =~ ^[0-9]+$ ]] || interval=5
  deadline=$((SECONDS + timeout))

  while ((SECONDS <= deadline)); do
    status=$(docker inspect -f '{{.State.Health.Status}}' "${container}" 2>/dev/null || true)
    if [[ "${status}" == "healthy" ]]; then
      return 0
    fi
    if ((SECONDS >= deadline)); then
      break
    fi
    echo "Waiting for ${container} to be healthy (${status:-not found})..."
    sleep "${interval}"
  done

  log_error "Timed out waiting for ${container} to become healthy after ${timeout}s"
  docker logs --tail 50 "${container}" >&2 2>/dev/null || true
  return 1
}

function perform_db_migrations() {
  db_host=$(get_config DB_HOST)
  redis_host=$(get_config REDIS_HOST)

  create_db_ops_env || return 1
  case "${db_host}" in
    mysql|postgresql)
      wait_container_healthy "xpam_${db_host}" || return 1
      ;;
  esac

  if [[ "${redis_host}" == "redis" ]]; then
    wait_container_healthy xpam_redis || return 1
  fi

  docker exec -i xpam_core bash -c './jms upgrade_db' || {
    log_error "$(gettext 'Failed to change the table structure')!"
    return 1
  }
}

function set_current_version() {
  current_version=$(get_config CURRENT_VERSION)
  if [ "${current_version}" != "${VERSION}" ]; then
    set_config CURRENT_VERSION "${VERSION}"
  fi
}

function get_current_version() {
  current_version=$(get_config CURRENT_VERSION "${VERSION}")
  echo "${current_version}"
}

# What "xpamctl version" shows: the XPAM release and, for support, the exact build of each image
function show_xpam_version() {
  local name image id

  echo "XPAM $(get_xpam_version)"
  for name in core gateway web workspace secureconnection webconnector ai; do
    image="$(get_xpam_namespace)/${name}:$(get_xpam_version)"
    id=$(docker image inspect -f '{{.Id}}' "${image}" 2>/dev/null | cut -c8-19)
    printf '  %-18s %s\n' "${name}" "${id:-not downloaded}"
  done
}

# XPAM does not report installations or upgrades to anyone (upstream sent a usage ping here).
function installation_log() {
  return 0
}

# Starts (or refreshes) all services and waits until they are ready.
function start_xpam_and_wait() {
  if ! bash "${PROJECT_DIR}/xpamctl.sh" start; then
    log_error "XPAM did not start. Look at: xpamctl status   and   xpamctl tail"
    return 1
  fi
  echo
  echo "Waiting for the services to become ready (usually one to three minutes) ..."
  if wait_xpam_healthy 420; then
    echo_done
  else
    log_warn "Some services are not ready yet. Check again in a minute with: xpamctl status"
  fi
  return 0
}

# Waits until every running XPAM container reports healthy, or the time (seconds) runs out.
function wait_xpam_healthy() {
  local timeout=${1:-300} waited=0 pending='' total=0

  while ((waited < timeout)); do
    total=$(docker ps --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" -q | wc -l)
    pending=$(docker ps --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}" \
      --format '{{.Names}} {{.Status}}' | grep -v '(healthy)' | awk '{print $1}' | tr '\n' ' ')
    if [[ "${total}" -gt 0 && -z "${pending// /}" ]]; then
      return 0
    fi
    sleep 5
    waited=$((waited + 5))
  done
  [[ -n "${pending// /}" ]] && echo "Not ready: ${pending}"
  return 1
}
