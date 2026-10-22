#!/usr/bin/env bash
#
export SHELLOPTS
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

. "${BASE_DIR}/utils.sh"

function pre_install() {
  if [[ -n "$UNCHECK_DEPENDENCIES" ]]; then
    return 0
  fi

  if ! ensure_required_tools; then
    exit 1
  fi

  if ! command -v systemctl &>/dev/null; then
    docker version &>/dev/null || {
      log_error "$(gettext 'The current Linux system does not support systemd management. Please deploy docker by yourself before running this script again')"
      exit 1
    }
    docker compose version &>/dev/null || {
      log_error "$(gettext 'The current Linux system does not support systemd management. Please deploy docker-compose by yourself before running this script again')"
      exit 1
    }
  fi

  if ! ensure_iptables; then
    exit 1
  fi

  found=0
  for cmd in python python2 python3; do
    if command -v "$cmd" &>/dev/null; then
      found=1
    break
  fi
  done
  
  if [ $found -eq 0 ]; then
    log_error "$(gettext 'command not found, Please install it first') python"
    exit 1
  fi
}

# https://<name or address>[:port], the address people open in the browser
function get_web_url() {
  local host http_port https_port server_name

  host=$(get_host_ip)
  http_port=$(get_config HTTP_PORT 80)
  https_port=$(get_config HTTPS_PORT 443)
  server_name=$(get_config SERVER_NAME)
  server_name=${server_name%%,*}
  [[ -n "${server_name}" && "${server_name}" != "_" ]] && host=${server_name}
  if [[ -n "${https_port}" ]]; then
    [[ "${https_port}" == "443" ]] && echo "https://${host}" || echo "https://${host}:${https_port}"
  else
    [[ "${http_port}" == "80" ]] && echo "http://${host}" || echo "http://${host}:${http_port}"
  fi
}

# Starts XPAM right after the installation unless the administrator declines.
function start_after_install() {
  local confirm="y"

  read_from_input confirm "Start XPAM now?" "y/n" "${confirm}"
  if [[ "${confirm}" != "y" ]]; then
    return 1
  fi
  start_xpam_and_wait
}

# XPAM: secrets in HashiCorp Vault from the start — Vault servers of their own (the XPAM Vault kit, recommended)
# or a hardened Vault on this server (moved to separate servers later with `xpamctl vault connect`).
#   XPAM_VAULT_MODE=external (with XPAM_VAULT_BUNDLE=<xpam-vault-IP.enc>) | local | none
function setup_vault_after_install() {
  local mode bundle choice keep keep_flag=""
  mode=$(get_config_or_env XPAM_VAULT_MODE)
  bundle=$(get_config_or_env XPAM_VAULT_BUNDLE)
  keep=$(get_config_or_env XPAM_VAULT_KEEP_DB_COPY)
  if [[ -z "${mode}" ]]; then
    if [[ -n "${bundle}" ]]; then
      mode=external
    elif [[ "${AUTO_INSTALL:-}" == "1" || ! -t 0 ]]; then
      mode=local
    else
      echo_yellow "\n>>> Where should XPAM keep its secrets (SECRET_KEY, passwords, account passwords)?"
      echo "  1) HashiCorp Vault on servers of its own (the XPAM Vault kit) — recommended"
      echo "  2) A hardened HashiCorp Vault on this server — move it to separate servers later (xpamctl vault connect)"
      echo "  3) On this server only (config.txt and the database)"
      choice=2
      read_from_input choice "Choice" "1/2/3" "${choice}"
      case "${choice}" in
        1) mode=external; read_from_input bundle "Vault bundle for this server (xpam-vault-IP.enc)" "" "" ;;
        3) mode=none ;;
        *) mode=local ;;
      esac
      if [[ "${mode}" != none && -z "${keep}" ]]; then
        echo "  Account passwords go to Vault only. A copy can also stay in the database (encrypted), read when Vault"
        echo "  does not answer — easier to recover, but the database then holds them too (xpamctl vault keep-db-copy on|off)."
        keep=n
        read_from_input keep "Keep a copy of account passwords in the database too?" "y/n" "${keep}"
      fi
    fi
  fi
  [[ "${keep}" =~ ^([yY]|[yY]es|1|true)$ ]] && keep_flag=--keep-db-copy
  case "${mode}" in
    external)
      echo_green "\n>>> $(gettext 'Secrets into HashiCorp Vault')"
      bash "${BASE_DIR}/vault.sh" connect "${bundle}" -y ${keep_flag} \
        || log_error "Vault was not connected; XPAM runs with its secrets on this server. Retry: xpamctl vault connect <bundle>"
      ;;
    local)
      echo_green "\n>>> $(gettext 'Secrets into a hardened Vault on this server')"
      bash "${BASE_DIR}/vault.sh" local ${keep_flag} \
        || log_error "The local Vault was not set up; XPAM runs with its secrets on this server. Retry: xpamctl vault local"
      ;;
    *)
      echo_warn "XPAM's secrets stay on this server (config.txt). Later: xpamctl vault local, or xpamctl vault connect <bundle>"
      # at least versioned data keys, rotated without downtime (the keyring is protected by SECRET_KEY)
      bash "${BASE_DIR}/vault.sh" data-key local >/dev/null 2>&1 || true
      ;;
  esac
}

function post_install() {
  local started=$1 ssh_port

  ssh_port=$(get_config KOKO_SSH_PORT 2222)
  if [[ "${started}" == "1" ]]; then
    echo_green "\n>>> XPAM is installed and running"
  else
    echo_green "\n>>> XPAM is installed"
    echo_yellow "Start it with:"
    echo "  xpamctl start"
  fi

  echo_yellow "\n1. Open in a browser"
  echo "  $(get_web_url)"
  echo "  The browser warns about the certificate until you install your own."

  echo_yellow "\n2. First sign-in"
  echo "  User: admin    Password: ChangeMe"
  echo "  You are asked to choose a new password (at least 14 characters with upper case,"
  echo "  lower case and a number)."

  echo_yellow "\n3. Everyday commands (from any folder)"
  echo "  xpamctl status      xpamctl start       xpamctl stop      xpamctl restart"
  echo "  xpamctl upgrade     xpamctl backup_db   xpamctl tail      xpamctl --help"

  echo_yellow "\n4. SSH client access"
  echo "  ssh -p ${ssh_port} <user>@$(get_host_ip)"

  echo_yellow "\nGuide: ${PROJECT_DIR}/docs/INSTALL.md"
  echo
}

function main() {
  echo_logo
  pre_install
  prepare_config
  set_current_version

  echo_green "\n>>> $(gettext 'Install and Configure Docker')"
  if ! bash "${BASE_DIR}/2_install_docker.sh"; then
    exit 1
  fi

  echo_green "\n>>> $(gettext 'Install and Configure XPAM')"
  if ! bash "${BASE_DIR}/1_config_xpam.sh"; then
    exit 1
  fi
  if ! configure_jdmc; then
    log_error "Failed to configure JDMC"
    exit 1
  fi

  echo_green "\n>>> $(gettext 'Loading Docker Image')"
  if ! bash "${BASE_DIR}/3_load_images.sh"; then
    exit 1
  fi

  echo_green "\n>>> $(gettext 'Initialize Database')"
  if ! perform_db_migrations; then
    log_error "$(gettext 'Failed to change the table structure')!"
    exit 1
  fi

  ensure_core_data_symlink || log_warn "Failed to prepare host core data symlink, continue installation"
  ensure_current_installer_link || {
    log_error "Failed to update /opt/current/installer"
    exit 1
  }
  install_jdmc || {
    log_error "Failed to install JDMC"
    exit 1
  }
 
  local started=0
  if start_after_install; then
    started=1
    setup_vault_after_install
  fi
  post_install "${started}"
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main
fi
