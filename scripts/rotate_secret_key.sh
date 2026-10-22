#!/usr/bin/env bash
#
# XPAM: replace SECRET_KEY and re-encrypt everything that depends on it.
#
#   xpamctl rotate-secret-key [-y]                    rotate now
#   xpamctl rotate-secret-key --schedule monthly|weekly|off [-y]   rotate on a schedule (systemd timer)
#
# With a data key (XPAM_DATA_KEY=transit or local, the default with Vault and on new installations) the secrets do
# not depend on SECRET_KEY: the rotation keeps everybody signed in. XPAM restarts with the new key and the previous
# one as a fallback (SECRET_KEY_PREVIOUS: sessions and signed values stay valid), then the keyring is re-wrapped and
# the e-mail lookups recomputed. Only the restart of the containers is felt.
#
# Without a data key (legacy): 1. backup of the database and of config.txt  2. XPAM stopped (database and Redis
# keep running)  3. re-encryption in one database transaction  4. new key saved, cache cleared, XPAM started —
# everybody signs in again. If step 3 fails, nothing is changed and XPAM starts again with the old key.
set -o pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
. "${BASE_DIR}/utils.sh"

function core_shell() { docker exec -i xpam_core bash -c "cd /opt/jumpserver/apps && python manage.py shell" >/dev/null 2>&1; }

function wait_core() {
  local i
  for i in $(seq 1 90); do docker ps --format '{{.Names}} {{.Status}}' | grep -q '^xpam_core .*(healthy)' && return 0; sleep 5; done
  return 1
}

function oneoff_args() { # the re-encryption container: XPAM's settings, and with Vault its secrets and client certificate
  ONEOFF=(--env-file "${CONFIG_FILE}")
  if secrets_from_vault; then
    ONEOFF+=(-v "${XPAM_SECRETS_RUN_DIR}/core:/run/xpam-secrets:ro"
             -v "${CONFIG_DIR}/vault/ca.crt:/opt/xpam-vault-client/ca.crt:ro"
             -v "${CONFIG_DIR}/vault/client.crt:/opt/xpam-vault-client/client.crt:ro"
             -v "${CONFIG_DIR}/vault/client.key:/opt/xpam-vault-client/client.key:ro")
  fi
}

function accounts_back_to_vault() {
  secrets_from_vault || return 0
  wait_core
  core_shell <<'PY' || log_warn "Moving the account secrets back to Vault failed: run it from the console (System settings → Vault → Sync)"
from accounts.tasks.vault import sync_secret_to_vault
sync_secret_to_vault()
PY
}

# ---------------------------------------------------------------- with a data key: nobody signed out

function rotate_keep_sessions() {
  local image=$1 old_key new_key
  old_key=$(get_config SECRET_KEY)
  new_key=$(random_str 50)

  echo_yellow "\n1. Backup"
  bash "${BASE_DIR}/5_db_backup.sh" || { log_error "Database backup failed: nothing was changed"; return 1; }

  echo_yellow "\n2. New key, the previous one kept as a fallback; XPAM restarts (sessions stay valid)"
  set_config SECRET_KEY_PREVIOUS "${old_key}" || return 1
  set_config SECRET_KEY "${new_key}" || { set_config SECRET_KEY_PREVIOUS ""; return 1; }
  (cd "${PROJECT_DIR}" && bash ./xpamctl.sh restart >/dev/null 2>&1)
  wait_core || log_warn "XPAM is slow to start; the re-encryption goes on"

  echo_yellow "\n3. Keyring re-wrapped, e-mail lookups recomputed (XPAM running)"
  oneoff_args
  # the command runs with the previous key as SECRET_KEY and the new one in NEW_SECRET_KEY (by name only)
  if SECRET_KEY="${old_key}" NEW_SECRET_KEY="${new_key}" docker run --rm --network xpam_net "${ONEOFF[@]}" \
      --env SECRET_KEY --env NEW_SECRET_KEY -w /opt/jumpserver/apps --entrypoint /opt/py3/bin/python "${image}" \
      manage.py rotate_secret_key; then
    echo_green "\nSECRET_KEY rotated; nobody was signed out (the previous key stays valid until the next rotation)."
  else
    log_error "The re-encryption failed: XPAM runs with the new key and the previous one as a fallback (nothing is lost); run it again: xpamctl rotate-secret-key"
    return 1
  fi
}

# ---------------------------------------------------------------- legacy (SECRET_KEY encrypts the secrets)

function rotate_legacy() {
  local image=$1 backup_dir config_backup new_key vault_mode=""
  if secrets_from_vault; then
    vault_mode=1
    echo_yellow "\n0. Account secrets from Vault back into the database (for re-encryption)"
    core_shell <<'PY' || { log_error "Reading the account secrets from Vault failed: nothing was changed"; return 1; }
from accounts.tasks.vault import restore_secret_from_vault
restore_secret_from_vault()
PY
  fi

  echo_yellow "\n1. Backup"
  bash "${BASE_DIR}/5_db_backup.sh" || { log_error "Database backup failed: nothing was changed"; accounts_back_to_vault; return 1; }
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
  oneoff_args
  # the key reaches the container by name only (--env NAME): it never appears in a process list
  if NEW_SECRET_KEY="${new_key}" docker run --rm --network xpam_net "${ONEOFF[@]}" --env NEW_SECRET_KEY \
      -w /opt/jumpserver/apps --entrypoint /opt/py3/bin/python "${image}" manage.py rotate_secret_key; then
    set_config SECRET_KEY "${new_key}" || {
      log_error "Saving the new key failed: restore ${config_backup} and the database backup"
      return 1
    }
    echo_green "   done"
  else
    log_error "Re-encryption failed: nothing was changed, XPAM starts again with the old key"
    bash "${PROJECT_DIR}/xpamctl.sh" start
    accounts_back_to_vault
    return 1
  fi

  echo_yellow "\n4. Clearing the cache and starting XPAM"
  REDISCLI_AUTH="$(get_config REDIS_PASSWORD)" docker exec -e REDISCLI_AUTH xpam_redis redis-cli FLUSHALL >/dev/null || \
    log_warn "The cache could not be cleared; old sessions end when they expire"
  bash "${PROJECT_DIR}/xpamctl.sh" start || return 1
  if [[ -n "${vault_mode}" ]]; then
    echo_yellow "\n5. Account secrets back into Vault (encrypted with the new key)"
    accounts_back_to_vault
  fi
  echo_green "\nSECRET_KEY rotated. Keep ${config_backup} and the database backup until you have checked XPAM."
}

# ---------------------------------------------------------------- schedule

function rotate_schedule() { # monthly|weekly|off
  local when=$1 calendar
  case "${when}" in
    weekly) calendar='Sun *-*-* 04:30:00' ;;
    monthly) calendar='*-*-01 04:30:00' ;;
    off)
      systemctl disable --now xpam-rotate-secret-key.timer >/dev/null 2>&1 || true
      rm -f /etc/systemd/system/xpam-rotate-secret-key.{service,timer}; systemctl daemon-reload
      echo_check "SECRET_KEY rotation: not scheduled"; return 0 ;;
    *) echo "usage: xpamctl rotate-secret-key --schedule weekly|monthly|off"; return 2 ;;
  esac
  [[ "$(get_config XPAM_DATA_KEY legacy)" != legacy ]] || {
    log_error "Scheduled rotation needs a data key (Vault, or: xpamctl vault data-key local): without one every rotation signs everybody out"
    return 1; }
  cat > /etc/systemd/system/xpam-rotate-secret-key.service <<EOF
[Unit]
Description=XPAM: rotate SECRET_KEY (sessions kept)
After=docker.service
[Service]
Type=oneshot
ExecStart=/bin/bash ${BASE_DIR}/rotate_secret_key.sh -y
EOF
  cat > /etc/systemd/system/xpam-rotate-secret-key.timer <<EOF
[Unit]
Description=XPAM: rotate SECRET_KEY (${when})
[Timer]
OnCalendar=${calendar}
Persistent=true
RandomizedDelaySec=30m
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now xpam-rotate-secret-key.timer >/dev/null 2>&1
  echo_check "SECRET_KEY rotation: ${when} ($(systemctl list-timers xpam-rotate-secret-key.timer --no-legend 2>/dev/null | awk '{print $1, $2, $3}'))"
}

function rotate_main() {
  local assume_yes="" schedule=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y) assume_yes=-y; shift ;;
      --schedule) schedule=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -n "${schedule}" ]] && { rotate_schedule "${schedule}"; return; }

  if ! docker ps --format '{{.Names}}' | grep -qx xpam_core; then
    log_error "XPAM must be running (the backup and the image are taken from it)"
    return 1
  fi
  local data_key image
  data_key=$(get_config XPAM_DATA_KEY legacy)
  echo_yellow "SECRET_KEY rotation"
  if [[ "${data_key}" != legacy ]]; then
    echo "  - the secrets are encrypted with the data key (${data_key}): nothing to re-encrypt"
    echo "  - XPAM restarts once; nobody is signed out"
  else
    echo "  - every stored secret is re-encrypted with a new key (one transaction, all or nothing)"
    echo "  - XPAM is offline for a few minutes and everybody signs in again"
  fi
  echo "  - a database backup is made first"
  if [[ "${assume_yes}" != "-y" ]]; then
    local confirm="n"
    read_from_input confirm "$(gettext 'Rotate SECRET_KEY now')?" "y/n" "${confirm}"
    [[ "${confirm}" == "y" ]] || return 1
  fi
  image=$(docker inspect xpam_core --format '{{.Config.Image}}') || return 1
  if [[ "${data_key}" != legacy ]]; then
    rotate_keep_sessions "${image}"
  else
    rotate_legacy "${image}"
  fi
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  rotate_main "$@"
fi
