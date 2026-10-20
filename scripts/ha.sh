#!/usr/bin/env bash
#
# XPAM high availability: two servers (one primary, one standby) and a witness.
#
#   xpamctl ha init <this-ip> <other-server-ip> <witness-ip>   on the current XPAM server (becomes primary)
#   xpamctl ha join <xpam-ha-join.tgz> [-y]                     on the second server (becomes standby)
#   (witness)  tar xzf xpam-ha-witness.tgz && ./witness.sh      on the witness (Docker only)
#   xpamctl ha status                                           roles, replication, files, witness
#   xpamctl ha switchover                                       planned: the other server becomes primary
#   xpamctl ha failover --force                                 emergency: make THIS server primary
#
# PostgreSQL runs under Patroni (automatic failover decided by a vote of both servers and the witness);
# the agent (systemd service xpam-ha) starts XPAM on the primary only and copies files to the standby.
set -o pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
. "${BASE_DIR}/utils.sh"

HA_DIR="${CONFIG_DIR}/ha"

function valid_ip() {
  python3 -c 'import ipaddress,sys; ipaddress.IPv4Address(sys.argv[1])' "$1" 2>/dev/null
}

function local_ip() {
  ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | grep -qx "$1"
}

function patroni() { # path [curl args...] — this server's Patroni REST API
  local path=$1; shift
  curl -s --max-time 5 "$@" "http://$(get_config HA_NODE_IP):8008/${path}"
}

function patroni_code() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$(get_config HA_NODE_IP):8008/$1"
}

function wait_until() { # seconds message command...
  local seconds=$1 message=$2; shift 2
  local start
  start=$(date +%s)
  until "$@"; do
    if (( $(date +%s) - start > seconds )); then
      return 1
    fi
    echo "  ${message}..."
    sleep 5
  done
}

function app_cmd() {
  get_docker_compose_cmd_line "ignore_db"
}

function db_cmd() {
  get_db_compose_cmd
}

# ---------------------------------------------------------------- used by the agent

function app_start() {
  # through xpamctl: the usual preparation steps run (it starts XPAM only when this server is primary)
  bash "${PROJECT_DIR}/xpamctl.sh" start
}

function app_stop() {
  local cmd
  cmd=$(app_cmd)
  cd "${PROJECT_DIR}" || return 1
  ${cmd} stop
}

# ---------------------------------------------------------------- common steps

function install_agent() {
  local peer=$1 volume_dir authorized line
  volume_dir=$(get_config VOLUME_DIR)
  # the other server may copy files into XPAM's data folder, nothing else
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  authorized=/root/.ssh/authorized_keys
  touch "${authorized}" && chmod 600 "${authorized}"
  sed -i '/ xpam-ha$/d' "${authorized}"
  line="from=\"${peer}\",restrict,command=\"${PROJECT_DIR}/ha/rsync-only.sh ${volume_dir}/core/data\" $(cat "${HA_DIR}/ssh/id_ed25519.pub")"
  echo "${line}" >> "${authorized}"
  sed "s#/opt/xpam-installer#${PROJECT_DIR}#g" "${PROJECT_DIR}/ha/xpam-ha.service" > /etc/systemd/system/xpam-ha.service
  systemctl daemon-reload
  systemctl enable --now xpam-ha >/dev/null 2>&1 || systemctl restart xpam-ha
  systemctl restart xpam-ha
}

function check_requirements() {
  local missing=""
  for c in rsync ssh ssh-keygen openssl curl iptables python3; do
    command -v "$c" >/dev/null 2>&1 || missing+=" $c"
  done
  if [[ -n "${missing}" ]]; then
    log_error "Missing on this server:${missing} (e.g. dnf install -y rsync openssh-clients openssl curl iptables)"
    return 1
  fi
  if [[ "$(get_config DB_ENGINE)" != "postgresql" || "$(get_config DB_HOST)" != "postgresql" ]]; then
    log_error "High availability needs XPAM's own PostgreSQL (DB_ENGINE=postgresql, DB_HOST=postgresql)"
    return 1
  fi
}

# ---------------------------------------------------------------- init (first server)

function ha_init() {
  local this=$1 peer=$2 witness=$3
  if is_ha_enabled; then
    log_error "High availability is already enabled on this server (xpamctl ha status)"
    return 1
  fi
  for ip in "${this}" "${peer}" "${witness}"; do
    valid_ip "${ip}" || { log_error "Not an IPv4 address: ${ip}"; return 1; }
  done
  if [[ "${this}" == "${peer}" || "${this}" == "${witness}" || "${peer}" == "${witness}" ]]; then
    log_error "The three addresses must be different"; return 1
  fi
  local_ip "${this}" || { log_error "${this} is not an address of this server"; return 1; }
  check_requirements || return 1
  docker ps --format '{{.Names}}' | grep -qx xpam_core || { log_error "XPAM must be running"; return 1; }

  echo_yellow "XPAM high availability"
  echo "  this server  ${this}   (becomes the primary)"
  echo "  other server ${peer}   (becomes the standby; install the same XPAM version there first)"
  echo "  witness      ${witness}   (any small machine with Docker; votes, holds no data)"
  echo "  XPAM is offline for a few minutes while the database is switched."
  if [[ "${4:-}" != "-y" && "${ASSUME_YES:-}" != "1" ]]; then
    local confirm="n"
    read_from_input confirm "Continue?" "y/n" "${confirm}"
    [[ "${confirm}" == "y" ]] || return 1
  fi

  # 1. secrets, certificates and keys (kept when init is run again)
  umask 077
  mkdir -p "${HA_DIR}/ssh"
  [[ -s "${HA_DIR}/certs/node.crt" ]] || bash "${PROJECT_DIR}/ha/certs.sh" "${HA_DIR}/certs" "${this}" "${peer}" "${witness}"
  [[ -s "${HA_DIR}/ssh/id_ed25519" ]] || ssh-keygen -q -t ed25519 -N '' -C xpam-ha -f "${HA_DIR}/ssh/id_ed25519"
  [[ -n "$(get_config HA_REPL_PASSWORD)" ]] || set_config HA_REPL_PASSWORD "$(random_str 32)"
  [[ -n "$(get_config HA_PATRONI_PASSWORD)" ]] || set_config HA_PATRONI_PASSWORD "$(random_str 32)"
  set_config HA_NODE_NAME xpam-a
  set_config HA_PEER_NAME xpam-b
  set_config HA_NODE_IP "${this}"
  set_config HA_PEER_IP "${peer}"
  set_config HA_WITNESS_IP "${witness}"
  set_config HA_ETCD_CLUSTER "xpam-a=https://${this}:2380,xpam-b=https://${peer}:2380,xpam-witness=https://${witness}:2380"

  # 2. the replication user (password from the environment, never on a command line)
  local db_user db_name
  db_user=$(get_config DB_USER); db_name=$(get_config DB_NAME)
  HA_RP="$(get_config HA_REPL_PASSWORD)" docker exec -i -e HA_RP xpam_postgresql \
    psql -v ON_ERROR_STOP=1 -U "${db_user}" -d "${db_name}" -q <<'SQL' || { log_error "The replication user could not be created"; return 1; }
\set rp `printenv HA_RP`
SELECT format('CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD %L', :'rp')
  WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') \gexec
SELECT format('ALTER ROLE replicator WITH REPLICATION LOGIN PASSWORD %L', :'rp') \gexec
SQL

  # 3. bundles: the witness gets only the certificates; the other server gets the configuration
  local work
  work=$(mktemp -d)
  mkdir -p "${work}/witness/certs"
  cp "${HA_DIR}/certs/ca.crt" "${HA_DIR}/certs/node.crt" "${HA_DIR}/certs/node.key" "${work}/witness/certs/"
  sed -e "s#@THIS@#${witness}#g" -e "s#@CLUSTER@#$(get_config HA_ETCD_CLUSTER)#g" \
      -e "s#@ALLOWED@#${this} ${peer}#g" "${PROJECT_DIR}/ha/witness.sh.in" > "${work}/witness/witness.sh"
  chmod 700 "${work}/witness/witness.sh"
  tar czf "${HA_DIR}/xpam-ha-witness.tgz" -C "${work}/witness" .
  mkdir -p "${work}/join/ha"
  cp "${CONFIG_FILE}" "${work}/join/config.txt"
  cp -r "${HA_DIR}/certs" "${HA_DIR}/ssh" "${work}/join/ha/"
  tar czf "${HA_DIR}/xpam-ha-join.tgz" -C "${work}/join" .
  rm -rf "${work}"

  echo_green "\nPrepared. Now:"
  echo "  1. witness ${witness}: copy ${HA_DIR}/xpam-ha-witness.tgz there and run:"
  echo "       mkdir xpam-witness && tar xzf xpam-ha-witness.tgz -C xpam-witness && ./xpam-witness/witness.sh"
  echo "  2. this server continues by itself as soon as the witness answers."
  echo "  3. afterwards, on ${peer}: copy ${HA_DIR}/xpam-ha-join.tgz there (it holds XPAM's secrets: delete it after) and run:"
  echo "       xpamctl ha join xpam-ha-join.tgz"
  echo
  wait_until 3600 "waiting for the witness on ${witness}:2379" bash -c "exec 3<>/dev/tcp/${witness}/2379" 2>/dev/null || {
    log_error "The witness did not answer. Run 'xpamctl ha init ${this} ${peer} ${witness}' again when it runs."; return 1; }

  # 4. backup, then switch the database to Patroni
  echo_yellow "\nBackup"
  bash "${BASE_DIR}/5_db_backup.sh" || { log_error "Database backup failed: nothing was changed"; return 1; }
  local old_cmd
  old_cmd=$(get_docker_compose_cmd_line)
  set_config HA_ENABLED 1
  echo_yellow "\nImages"
  if ! pull_images; then
    set_config HA_ENABLED 0
    log_error "The high availability images are not available: nothing was changed"; return 1
  fi
  echo_yellow "\nSwitching the database (XPAM is offline now)"
  cd "${PROJECT_DIR}" || return 1
  ${old_cmd} down
  mkdir -p "$(get_config VOLUME_DIR)/etcd"
  $(db_cmd) up -d
  if ! wait_until 300 "waiting for PostgreSQL under Patroni to become primary" \
      bash -c '[[ $(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://'"${this}"':8008/primary") == 200 ]]'; then
    log_error "PostgreSQL did not become primary: 'docker logs xpam_postgresql'. To go back: set HA_ENABLED=0 in config.txt and xpamctl start"
    return 1
  fi
  install_agent "${peer}"
  wait_until 600 "waiting for XPAM to start" bash -c 'docker ps --format "{{.Names}} {{.Status}}" | grep -q "^xpam_core .*(healthy)"' || true
  echo_green "\nThis server is the primary. Next: 'xpamctl ha join xpam-ha-join.tgz' on ${peer}."
}

# ---------------------------------------------------------------- join (second server)

function ha_join() {
  local bundle=$1 assume=${2:-}
  [[ -f "${bundle}" ]] || { log_error "Bundle not found: ${bundle}"; return 1; }
  if is_ha_enabled; then
    log_error "High availability is already enabled on this server"; return 1
  fi
  check_requirements || return 1
  local work
  work=$(mktemp -d)
  tar xzf "${bundle}" -C "${work}" || { log_error "Not an XPAM high availability bundle"; return 1; }
  [[ -f "${work}/config.txt" && -s "${work}/ha/certs/node.crt" ]] || { log_error "Not an XPAM high availability bundle"; return 1; }
  local this peer witness bundle_version
  this=$(grep '^HA_PEER_IP=' "${work}/config.txt" | cut -d= -f2-)
  peer=$(grep '^HA_NODE_IP=' "${work}/config.txt" | cut -d= -f2-)
  witness=$(grep '^HA_WITNESS_IP=' "${work}/config.txt" | cut -d= -f2-)
  bundle_version=$(grep '^CURRENT_VERSION=' "${work}/config.txt" | cut -d= -f2-)
  local_ip "${this}" || { log_error "This server is not ${this} (the address given to 'ha init')"; rm -rf "${work}"; return 1; }
  if [[ -n "${bundle_version}" && "${bundle_version}" != "$(get_config CURRENT_VERSION)" ]]; then
    log_error "The primary runs ${bundle_version}, this server $(get_config CURRENT_VERSION): install the same version first"
    rm -rf "${work}"; return 1
  fi
  echo_yellow "XPAM high availability: this server (${this}) becomes the standby of ${peer}"
  echo "  This server's own XPAM data is replaced by the primary's (its database is kept aside)."
  if [[ "${assume}" != "-y" ]]; then
    local confirm="n"
    read_from_input confirm "Continue?" "y/n" "${confirm}"
    [[ "${confirm}" == "y" ]] || { rm -rf "${work}"; return 1; }
  fi
  bash -c "exec 3<>/dev/tcp/${peer}/8008" 2>/dev/null || { log_error "The primary ${peer} is not reachable on port 8008"; rm -rf "${work}"; return 1; }

  local volume_dir config_dir stamp old_cmd
  volume_dir=$(get_config VOLUME_DIR); config_dir=$(get_config CONFIG_DIR)
  stamp=$(date +%F_%H%M%S)
  old_cmd=$(get_docker_compose_cmd_line)
  cd "${PROJECT_DIR}" || return 1
  ${old_cmd} down
  umask 077
  cp -p "${CONFIG_FILE}" "${CONFIG_FILE}.before-ha-${stamp}"
  if [[ -d "${volume_dir}/postgresql/data" ]]; then
    mv "${volume_dir}/postgresql/data" "${volume_dir}/postgresql/data.before-ha-${stamp}"
  fi
  mkdir -p "${volume_dir}/postgresql/data" "${volume_dir}/etcd"
  # the primary's configuration (same keys and passwords), with this server's own role and paths
  cp "${work}/config.txt" "${CONFIG_FILE}"
  set_config VOLUME_DIR "${volume_dir}"
  set_config CONFIG_DIR "${config_dir}"
  set_config HA_NODE_NAME xpam-b
  set_config HA_PEER_NAME xpam-a
  set_config HA_NODE_IP "${this}"
  set_config HA_PEER_IP "${peer}"
  set_config HA_ENABLED 1
  rm -rf "${HA_DIR}" && mkdir -p "${HA_DIR}"
  cp -r "${work}/ha/certs" "${work}/ha/ssh" "${HA_DIR}/"
  rm -rf "${work}"
  echo_yellow "\nImages"
  pull_images || { log_error "The images are not available"; return 1; }
  echo_yellow "\nCopying the database from the primary"
  $(db_cmd) up -d
  if ! wait_until 7200 "copying (large databases take a while)" \
      bash -c '[[ $(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://'"${this}"':8008/replica") == 200 ]]'; then
    log_error "The database could not be copied: 'docker logs xpam_postgresql'"; return 1
  fi
  install_agent "${peer}"
  echo_green "\nThis server is the standby: it follows the primary and takes over by itself if the primary fails."
  echo "Delete the bundle (it holds XPAM's secrets): rm -f ${bundle}"
}

# ---------------------------------------------------------------- operations

function ha_status() {
  is_ha_enabled || { echo "High availability is not enabled (xpamctl ha init ...)"; return 0; }
  local status
  echo_yellow "Cluster"
  patroni cluster | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    print("  Patroni is not answering on this server"); sys.exit()
for m in d.get("members", []):
    lag = m.get("lag", "")
    print("  %-8s %-15s %-13s %-10s lag %s" % (m["name"], m.get("host", ""), m["role"], m["state"], lag if lag != "" else "-"))'
  status="$(get_config VOLUME_DIR)/core/data/ha/status.json"
  if [[ -f "${status}" ]]; then
    echo_yellow "This server"
    python3 - "${status}" <<'PY'
import json, sys, time
s = json.load(open(sys.argv[1]))
fs = s.get('file_sync') or {}
age = int(time.time()) - int(s.get('updated') or 0)
print(f"  role {s['role']}, XPAM services {'running' if s['app_running'] else 'stopped'} (agent updated {age}s ago)")
print(f"  other server {'reachable' if s['peer_reachable'] else 'NOT reachable'}, witness {'reachable' if s['witness_reachable'] else 'NOT reachable'}")
if fs.get('time'):
    print(f"  file copy to the standby: {'ok' if fs['ok'] else 'FAILED ' + fs.get('error', '')} ({int(time.time()) - fs['time']}s ago)")
PY
  fi
}

function ha_switchover() {
  is_ha_enabled || { log_error "High availability is not enabled"; return 1; }
  local leader candidate code
  leader=$(patroni cluster | python3 -c 'import json,sys; print(next((m["name"] for m in json.load(sys.stdin)["members"] if m["role"] in ("leader","standby_leader")), ""))')
  candidate=$(patroni cluster | python3 -c 'import json,sys; print(next((m["name"] for m in json.load(sys.stdin)["members"] if m["role"] in ("sync_standby","replica") and m["state"] in ("streaming","running")), ""))')
  [[ -n "${leader}" && -n "${candidate}" ]] || { log_error "No healthy standby to switch to"; return 1; }
  echo "Switching the primary from ${leader} to ${candidate} (XPAM moves to the other server, about a minute)"
  code=$(HA_P="$(get_config HA_PATRONI_PASSWORD)" bash -c 'curl -s -o /dev/null -w "%{http_code}" --max-time 60 -u "patroni:${HA_P}" \
    -XPOST -H "Content-Type: application/json" -d "{\"leader\":\"'"${leader}"'\",\"candidate\":\"'"${candidate}"'\"}" \
    "http://'"$(get_config HA_NODE_IP)"':8008/switchover"')
  [[ "${code}" == "200" ]] || { log_error "Switchover refused (HTTP ${code}): the standby must be in sync ('xpamctl ha status')"; return 1; }
  echo_green "Done: ${candidate} is the primary."
}

function ha_failover() {
  is_ha_enabled || { log_error "High availability is not enabled"; return 1; }
  if [[ "${1:-}" != "--force" ]]; then
    echo "Makes THIS server the primary even when Patroni would not do it by itself (e.g. the standby was not"
    echo "in sync when the primary failed: the last transactions may be lost). Run with --force."
    return 1
  fi
  local code
  code=$(HA_P="$(get_config HA_PATRONI_PASSWORD)" bash -c 'curl -s -o /dev/null -w "%{http_code}" --max-time 60 -u "patroni:${HA_P}" \
    -XPOST -H "Content-Type: application/json" -d "{\"candidate\":\"'"$(get_config HA_NODE_NAME)"'\"}" \
    "http://'"$(get_config HA_NODE_IP)"':8008/failover"')
  [[ "${code}" == "200" ]] || { log_error "Failover refused (HTTP ${code}): 'docker logs xpam_postgresql'"; return 1; }
  echo_green "This server is the primary."
}

function ha_role() {
  # primary | standby | unknown (this server's database)
  case "$(patroni_code primary)" in
    200) echo primary ;;
    503) echo standby ;;
    *) echo unknown ;;
  esac
}

function ha_pause() { # on|off — maintenance mode: no automatic failover (upgrades)
  local value=true
  [[ "$1" == "off" ]] && value=null
  HA_P="$(get_config HA_PATRONI_PASSWORD)" bash -c 'curl -s -o /dev/null -w "%{http_code}" --max-time 15 -u "patroni:${HA_P}" \
    -XPATCH -H "Content-Type: application/json" -d "{\"pause\": '"${value}"'}" "http://'"$(get_config HA_NODE_IP)"':8008/config"' | grep -q 200
}

function main() {
  local action=${1:-status}; shift || true
  case "${action}" in
    init) [[ $# -ge 3 ]] || { echo "usage: xpamctl ha init <this-ip> <other-server-ip> <witness-ip>"; return 2; }
          ha_init "$@" ;;
    join) [[ $# -ge 1 ]] || { echo "usage: xpamctl ha join <xpam-ha-join.tgz> [-y]"; return 2; }
          ha_join "$@" ;;
    status) ha_status ;;
    switchover) ha_switchover ;;
    failover) ha_failover "$@" ;;
    role) ha_role ;;
    pause) ha_pause "${1:-on}" ;;
    app-start) app_start ;;
    app-stop) app_stop ;;
    *) echo "usage: xpamctl ha init|join|status|switchover|failover"; return 2 ;;
  esac
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main "$@"
fi
