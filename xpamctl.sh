#!/usr/bin/env bash
#
export SHELLOPTS

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

cd "${PROJECT_DIR}" || exit 1

. "${PROJECT_DIR}/scripts/utils.sh"

action=${1-}
target=${2-}
args=("$@")
skip_jdmc=false

if [[ "${target}" == "--skip-jdmc" ]]; then
  case "${action}" in
  start|stop|restart|close|status|down)
    skip_jdmc=true
    target=""
    ;;
  esac
fi

# XPAM names are accepted wherever one service is named (the Compose services keep short names)
case "${target}" in
  secureconnection) target=koko ;;
  webconnector) target=chen ;;
  ai) target=kael ;;
esac

function check_config_file() {
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "$(gettext 'Configuration file not found'): ${CONFIG_FILE}"
    echo "$(gettext 'If you are upgrading from v1.5.x, please copy the config.txt To') ${CONFIG_FILE}"
    return 3
  fi
  if [[ -f .env ]]; then
    if ! ls -l .env | grep "${CONFIG_FILE}" &>/dev/null; then
      echo ".env $(gettext 'There is a problem with the soft connection, Please update it again')"
      rm -f .env
    fi
  fi

  if [[ ! -f ".env" ]]; then
    ln -s "${CONFIG_FILE}" .env
  fi

  if [[ ! -f "./compose/.env" ]]; then
    ln -s "${CONFIG_FILE}" ./compose/.env
  fi
  gen_safe_config >/dev/null
}

function pre_check() {
  check_config_file || return 3
}

function usage() {
  echo "$(gettext 'XPAM Deployment Management Script')"
  echo
  echo "Usage: "
  echo "  ./xpamctl.sh [COMMAND] [ARGS...]"
  echo "  ./xpamctl.sh --help"
  echo
  echo "Installation Commands: "
  echo "  install           $(gettext 'Install XPAM')"
  echo "  upgrade           $(gettext 'Upgrade XPAM')"
  echo "  check_update      Check whether a newer installer is published"
  echo
  echo "Management Commands: "
  echo "  config            $(gettext 'Configuration  Tools')"
  echo "  start [--skip-jdmc]   $(gettext 'Start     XPAM')"
  echo "  stop [--skip-jdmc]    $(gettext 'Stop      XPAM')"
  echo "  restart [--skip-jdmc] $(gettext 'Restart   XPAM')"
  echo "  status [--skip-jdmc]  $(gettext 'Check     XPAM')"
  echo "  down              $(gettext 'Offline   XPAM')"
  echo "  uninstall         $(gettext 'Uninstall XPAM')"
  echo
  echo "More Commands: "
  echo "  load_image        $(gettext 'Loading docker image')"
  echo "  pull_images       Download the current XPAM images"
  echo "  backup_db         $(gettext 'Backup database')"
  echo "  backup_no_audit   $(gettext 'Backup database without audit data')"
  echo "  backup_audit      $(gettext 'Backup audits tables')"
  echo "  restore_db [file]        $(gettext 'Data recovery through database backup file')"
  echo "  rotate-secret-key [-y] [--schedule weekly|monthly|off]   Replace SECRET_KEY (with a data key: nobody signed out)"
  echo "  ha init|join|status|switchover|failover   High availability: two servers and a witness (see docs)"
  echo "  license-ids                                The cluster ID and this server's ID, for a licence"
  echo "  vault connect|status|disconnect           Secrets in HashiCorp Vault (the XPAM Vault kit, see docs)"
  echo "  fetch-applet-files       Put the Windows publishing host installers on this server (checksum checked)"
  echo "  raw               $(gettext 'Execute the original docker compose command')"
  echo "  tail [service]    $(gettext 'View log')"
  echo "  version           Show the XPAM release and the build of each image"
  echo
  echo "Services: core worker gateway web workspace secureconnection webconnector ai"
  echo
}

function service_to_docker_name() {
  service=$1
  case "${service}" in
    koko) service=secureconnection ;;
    chen) service=webconnector ;;
    kael) service=ai ;;
    celery) service=worker ;;
  esac
  if [[ "${service:0:5}" != "xpam_" ]]; then
    service=xpam_${service}
  fi
  echo "${service}"
}

EXE=""

function should_manage_jdmc() {
  [[ "${skip_jdmc}" != "true" ]]
}

function is_jdmc_target() {
  [[ "${target}" == "jdmc" ]]
}

function start() {
  set_openbao || return 1
  configure_jdmc || return 1
  gen_safe_config >/dev/null
  stop_disabled_video_worker || return 1
  prepare_video_worker_volume || return 1
  retire_legacy_project || return 1
  retire_combined_web || return 1
  retire_renamed_services || return 1
  if is_ha_enabled && [[ "$(bash "${SCRIPT_DIR}/ha.sh" role)" != "primary" ]]; then
    # high availability: XPAM's services run on the primary only (the agent starts them when this server becomes primary)
    EXE=$(get_db_compose_cmd)
    ${EXE} up -d || return 1
    echo "High availability: this server is not the primary; its database, Redis and vote are running."
    return 0
  fi
  EXE=$(get_docker_compose_cmd_line)
  ${EXE} up -d || return 1
  remove_stopped_openbao_init_container

  ensure_current_installer_link || return 1
  if should_manage_jdmc; then
    start_jdmc
  fi
}

function stop() {
  if is_jdmc_target; then
    stop_jdmc
  elif [[ "${target}" == "ignore_db" ]]; then
    if should_manage_jdmc; then
      stop_jdmc || return 1
    fi
    cmd=$(get_docker_compose_cmd_line "ignore_db")
    ${cmd} down -v
  elif [[ -n "${target}" ]]; then
    ${EXE} stop "${target}" && ${EXE} rm -f "${target}"
  else
    if should_manage_jdmc; then
      stop_jdmc || return 1
    fi
    retire_legacy_project || return 1
    ${EXE} down -v
  fi
}

function close() {
  if [[ -n "${target}" ]]; then
    if is_jdmc_target; then
      stop_jdmc
      return
    fi
    ${EXE} stop "${target}"
    return
  fi
  if should_manage_jdmc; then
    stop_jdmc || return 1
  fi
  services=$(get_docker_compose_services ignore_db)
  for i in ${services}; do
    ${EXE} stop "${i}"
  done
}

function pull() {
  # Through the installer's own image list (configured registry, or none when it is "local"),
  # never "docker compose pull": the bare xpam/* names would be fetched from Docker Hub.
  pull_images
}

function restart() {
  if is_jdmc_target; then
    restart_jdmc
    return
  fi
  stop || return 1
  echo -e "\n"

  if [[ -n "${target}" && "${target}" != "ignore_db" ]]; then
    ${EXE} up -d "${target}" || return 1
    remove_stopped_openbao_init_container
    return
  fi
  start
}

function clean() {
  rm -f scripts/docker/*
  rm -f scripts/images/*
}

function check_update() {
  local pending

  pending=$(get_pending_installer_updates)
  if [[ -z "${pending}" ]]; then
    echo "Cannot check for installer updates from here (no git checkout or no connection)."
    echo "xpamctl upgrade always downloads the current XPAM images."
  elif [[ "${pending}" == "0" ]]; then
    echo_green "The installer is up to date. xpamctl upgrade also refreshes the XPAM images."
  else
    echo_yellow "${pending} installer update(s) available. Run: xpamctl upgrade"
  fi
}

# Before an upgrade, bring the installer itself up to date when it is a git checkout, then run
# the upgrade with the new copy. Set XPAM_SKIP_SELF_UPDATE=1 to keep the installed copy.
function update_installer() {
  local before after

  [[ "${XPAM_SKIP_SELF_UPDATE:-}" == "1" ]] && return 0
  [[ -d "${PROJECT_DIR}/.git" ]] && command -v git &>/dev/null || return 0
  before=$(git -C "${PROJECT_DIR}" rev-parse HEAD 2>/dev/null) || return 0
  echo "Updating the installer ..."
  # "upgrade <version>" writes VERSION into static.env: put it back first, otherwise every later
  # update stops at "local changes" (the upgrade writes the chosen version again)
  if [[ -z "$(git -C "${PROJECT_DIR}" status --porcelain -- . ':!static.env' 2>/dev/null)" ]]; then
    git -C "${PROJECT_DIR}" checkout -- static.env 2>/dev/null
  fi
  if ! GIT_TERMINAL_PROMPT=0 timeout 120 git -C "${PROJECT_DIR}" pull --ff-only --quiet 2>/dev/null; then
    log_warn "The installer could not be updated from its repository; continuing with the installed copy"
    return 0
  fi
  after=$(git -C "${PROJECT_DIR}" rev-parse HEAD 2>/dev/null)
  if [[ "${before}" != "${after}" ]]; then
    echo "Installer updated, continuing with the new copy"
    XPAM_SKIP_SELF_UPDATE=1 exec bash "${PROJECT_DIR}/xpamctl.sh" "${args[@]}"
  fi
  return 0
}

function video-worker() {
  EXE=$(get_video_worker_cmd_line)
  if [[ ! "${EXE}" ]]; then
    log_error "video-worker is only available in the enterprise edition"
    return 1
  fi
  case "${target}" in
    start)
      if ! video_worker_can_start; then
        log_error "video-worker is disabled by VIDEO_WORKER_ENABLED=0"
        return 1
      fi
      prepare_video_worker_volume && ${EXE} up -d
      ;;
    stop) ${EXE} down -v ;;
    restart)
      if ! video_worker_can_start; then
        log_error "video-worker is disabled by VIDEO_WORKER_ENABLED=0"
        return 1
      fi
      ${EXE} down -v && prepare_video_worker_volume && ${EXE} up -d
      ;;
    status) ${EXE} ps ;;
    *)
      log_error "Usage: ./xpamctl.sh video-worker {start|stop|restart|status}"
      return 2
      ;;
  esac
}

function check_os() {
  if [[ -n "$UNCHECK_DEPENDENCIES" ]]; then
    return 0
  fi
  if [[ "${OS}" == 'Darwin' ]]; then
    echo
    echo "$(gettext 'Unsupported Operating System Error')"
    echo "XPAM is installed on a Linux server."
    return 1
  fi
  if [[ "${OS}" =~ MINGW.* ]]; then
    echo
    echo "$(gettext 'Unsupported Operating System Error')"
    echo "XPAM is installed on a Linux server."
    return 1
  fi
  return 0
}

function main() {
  check_os || return 3

  if [[ "${action}" == "help" || "${action}" == "h" || "${action}" == "-h" || "${action}" == "--help" ]]; then
    echo ""
  elif [[ "${action}" == "install" || "${action}" == "config" || "${action}" == "reconfig" || "${action}" == "uninstall" ]]; then
    echo ""
  else
    pre_check || return 3
    EXE=$(get_docker_compose_cmd_line)
  fi
  case "${action}" in
  install)
    bash "${SCRIPT_DIR}/4_install_xpam.sh"
    ;;
  upgrade)
    update_installer
    bash "${SCRIPT_DIR}/7_upgrade.sh" "$target"
    ;;
  check_update)
    check_update
    ;;
  config)
    bash "${SCRIPT_DIR}/config.sh" "$target"
    ;;
  reconfig)
    ${EXE} down -v
    bash "${SCRIPT_DIR}/1_config_xpam.sh"
    ;;
  start)
    start
    ;;
  restart)
    restart
    ;;
  stop)
    stop 
    ;;
  pull)
    pull
    ;;
  close)
    close
    ;;
  status)
    ${EXE} ps --format 'table {{.Name}}\t{{.Status}}\t{{.Ports}}'
    if should_manage_jdmc; then
      status_jdmc
    fi
    ;;
  down)
    if [[ -z "${target}" ]]; then
      if should_manage_jdmc; then
        stop_jdmc || exit 1
      fi
      retire_legacy_project || exit 1
      ${EXE} down -v
    elif is_jdmc_target; then
      stop_jdmc
    else
      ${EXE} stop "${target}" && ${EXE} rm -f "${target}"
    fi
    ;;
  uninstall)
    bash "${SCRIPT_DIR}/8_uninstall.sh"
    ;;
  migrate_db)
    if ! perform_db_migrations; then
      log_error "$(gettext 'Failed to change the table structure')!"
      exit 1
    fi
    ;;
  backup_db)
    bash "${SCRIPT_DIR}/5_db_backup.sh"
    ;;
  backup_no_audit)
    bash "${SCRIPT_DIR}/5_db_backup.sh" "no_audit"
    ;;
  backup_audit)
    bash "${SCRIPT_DIR}/5_db_backup.sh" "audit"
    ;;
  fetch-applet-files)
    bash "${SCRIPT_DIR}/fetch_applet_files.sh" "${target}"
    ;;
  ha)
    bash "${SCRIPT_DIR}/ha.sh" "${@:2}"
    ;;
  vault)
    bash "${SCRIPT_DIR}/vault.sh" "${@:2}"
    ;;
  rotate-secret-key)
    bash "${SCRIPT_DIR}/rotate_secret_key.sh" "${@:2}"
    ;;
  license-ids)
    bash "${SCRIPT_DIR}/license_ids.sh"
    ;;
  restore_db)
    bash "${SCRIPT_DIR}/6_db_restore.sh" "$target"
    ;;
  load_image)
    bash "${SCRIPT_DIR}/3_load_images.sh"
    ;;
  pull_images)
    pull_images
    ;;
  cmd)
    echo "${EXE}"
    ;;
  tail)
    if is_jdmc_target; then
      tail_jdmc
    elif [[ -z "${target}" ]]; then
      ${EXE} logs --tail 100 -f
    else
      docker_name=$(service_to_docker_name "${target}")
      docker logs -f "${docker_name}" --tail 100
    fi
    ;;
  show_services)
    get_docker_compose_services
    ;;
  init_db)
    perform_db_migrations
    ;;
  restart_db)
    db_redis_restart "${target}"
    ;;
  stop_db)
    db_redis_stop "${target}"
    ;;
  start_db)
    db_redis_start "${target}"
    ;;
  cmd_db)
    get_db_compose_cmd "${target}"
    ;;
  video-worker)
    video-worker
    ;;
  raw)
    ${EXE} "${args[@]:1}"
    ;;
  version)
    show_xpam_version
    ;;
  help)
    usage
    ;;
  --help)
    usage
    ;;
  -h)
    usage
    ;;
  *)
    echo "No such command: ${action}"
    usage
    return 2
    ;;
  esac
}

main "$@"
