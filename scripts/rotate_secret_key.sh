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

  # XPAM: with secrets in Vault, the account secrets there are encrypted with SECRET_KEY as well: they come
  # back into the database first, are re-encrypted with the rest, and go back to Vault with the new key
  local vault_mode="" run_args=()
  if secrets_from_vault; then
    vault_mode=1
    run_args=(-v "${XPAM_SECRETS_RUN_DIR}/core:/run/xpam-secrets:ro")
    echo_yellow "\n0. Account secrets from Vault back into the database (for re-encryption)"
    docker exec -i xpam_core bash -c "cd /opt/jumpserver/apps && python manage.py shell" >/dev/null 2>&1 <<'PY' || {
from accounts.tasks.vault import restore_secret_from_vault
restore_secret_from_vault()
PY
      log_error "Reading the account secrets from Vault failed: nothing was changed"; return 1; }
  fi

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
  if docker run --rm --network xpam_net --env-file "${CONFIG_FILE}" --env NEW_SECRET_KEY "${run_args[@]}" \
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
  REDISCLI_AUTH="$(get_config REDIS_PASSWORD)" docker exec -e REDISCLI_AUTH xpam_redis redis-cli FLUSHALL >/dev/null || \
    log_warn "The cache could not be cleared; old sessions end when they expire"
  bash "${PROJECT_DIR}/xpamctl.sh" start || return 1
  if [[ -n "${vault_mode}" ]]; then
    echo_yellow "\n5. Account secrets back into Vault (encrypted with the new key)"
    local i
    for i in $(seq 1 60); do docker ps --format '{{.Names}} {{.Status}}' | grep -q '^xpam_core .*(healthy)' && break; sleep 5; done
    docker exec -i xpam_core bash -c "cd /opt/jumpserver/apps && python manage.py shell" >/dev/null 2>&1 <<'PY' || {
from accounts.tasks.vault import sync_secret_to_vault
sync_secret_to_vault()
PY
      log_warn "Moving the account secrets back to Vault failed: run it from the console (System settings → Vault → Sync)"; }
    echo_green "\nSECRET_KEY rotated (the new key is in Vault; Vault keeps the previous one as an older version)."
    return 0
  fi
  echo_green "\nSECRET_KEY rotated. Keep ${config_backup} and the database backup until you have checked XPAM."
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  rotate_main "$@"
fi
