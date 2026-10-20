#!/usr/bin/env bash
#
# XPAM: replace SECRET_KEY and re-encrypt everything that depends on it.
#
# 1. backup of the database and of config.txt   2. XPAM stopped (database and Redis keep running)
# 3. re-encryption in one database transaction  4. new key saved, cache cleared, XPAM started.
# If step 3 fails, nothing is changed and XPAM starts again with the old key.
set -o pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
. "${BASE_DIR}/utils.sh"

function rotate_main() {
  local assume_yes=$1 image backup_dir config_backup new_key
  if ! docker ps --format '{{.Names}}' | grep -qx xpam_core; then
    log_error "XPAM must be running (the backup and the image are taken from it)"
    return 1
  fi
  echo_yellow "SECRET_KEY rotation"
  echo "  - every stored secret is re-encrypted with a new key (one transaction, all or nothing)"
  echo "  - XPAM is offline for a few minutes and everybody signs in again"
  echo "  - a database backup and a copy of config.txt are made first"
  if [[ "${assume_yes}" != "-y" ]]; then
    local confirm="n"
    read_from_input confirm "$(gettext 'Rotate SECRET_KEY now')?" "y/n" "${confirm}"
    [[ "${confirm}" == "y" ]] || return 1
  fi

  image=$(docker inspect xpam_core --format '{{.Config.Image}}') || return 1

  echo_yellow "\n1. Backup"
  bash "${BASE_DIR}/5_db_backup.sh" || { log_error "Database backup failed: nothing was changed"; return 1; }
  backup_dir="$(get_config VOLUME_DIR)/db_backup"
  config_backup="${backup_dir}/config-before-key-rotation-$(date +%F_%H%M%S).txt"
  (umask 077 && cp -p "${CONFIG_FILE}" "${config_backup}") || return 1
  echo "   config.txt saved to ${config_backup}"

  echo_yellow "\n2. Stopping XPAM (database and Redis keep running)"
  local cmd
  cmd=$(get_docker_compose_cmd_line "ignore_db")
  ${cmd} down || return 1

  echo_yellow "\n3. Re-encrypting"
  new_key=$(random_str 50)
  export NEW_SECRET_KEY="${new_key}"
  # the key reaches the container by name only (--env NAME): it never appears in a process list
  if docker run --rm --network xpam_net --env-file "${CONFIG_FILE}" --env NEW_SECRET_KEY \
      -w /opt/jumpserver/apps --entrypoint /opt/py3/bin/python "${image}" manage.py rotate_secret_key; then
    unset NEW_SECRET_KEY
    set_config SECRET_KEY "${new_key}" || {
      log_error "Saving the new key failed: restore ${config_backup} and the database backup"
      return 1
    }
    echo_green "   done"
  else
    unset NEW_SECRET_KEY
    log_error "Re-encryption failed: nothing was changed, XPAM starts again with the old key"
    bash "${PROJECT_DIR}/xpamctl.sh" start
    return 1
  fi

  echo_yellow "\n4. Clearing the cache and starting XPAM"
  docker exec xpam_redis sh -c 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli FLUSHALL' >/dev/null || \
    log_warn "The cache could not be cleared; old sessions end when they expire"
  bash "${PROJECT_DIR}/xpamctl.sh" start || return 1
  echo_green "\nSECRET_KEY rotated. Keep ${config_backup} and the database backup until you have checked XPAM."
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  rotate_main "$@"
fi
