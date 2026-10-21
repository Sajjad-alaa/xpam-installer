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
#   xpamctl ha vip <ip/prefix>|off                              floating address held by the primary (both servers)
#   xpamctl ha witness-bundle                                   replace the witness (same address)
#   xpamctl ha disable [-y]                                     back to one server (standby first, then primary)
#   xpamctl ha join-bundle                                      a fresh join bundle (to rebuild the other server)
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

function pcurl() { # curl with the cluster certificate (Patroni's API requires it)
  curl --cacert "${HA_DIR}/certs/ca.crt" --cert "${HA_DIR}/certs/node.crt" --key "${HA_DIR}/certs/node.key" "$@"
}

function patroni() { # path [curl args...] — this server's Patroni REST API
  local path=$1; shift
  pcurl -s --max-time 5 "$@" "https://$(get_config HA_NODE_IP):8008/${path}"
}

function patroni_code() { # path [host]
  pcurl -s -o /dev/null -w '%{http_code}' --max-time 5 "https://${2:-$(get_config HA_NODE_IP)}:8008/$1"
}

function patroni_write() { # method path json — with the REST password (from the environment, not the command line)
  HA_P="$(get_config HA_PATRONI_PASSWORD)" HA_C="${HA_DIR}/certs" HA_U="https://$(get_config HA_NODE_IP):8008/$2" \
    HA_M="$1" HA_D="$3" bash -c 'curl -s -o /dev/null -w "%{http_code}" --max-time 60 --cacert "$HA_C/ca.crt" \
      --cert "$HA_C/node.crt" --key "$HA_C/node.key" -u "patroni:${HA_P}" -X "$HA_M" \
      -H "Content-Type: application/json" -d "$HA_D" "$HA_U"'
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
  sed "s#/opt/xpam-installer#${PROJECT_DIR}#g" "${PROJECT_DIR}/ha/xpam-ha-firewall.service" > /etc/systemd/system/xpam-ha-firewall.service
  systemctl daemon-reload
  systemctl enable xpam-ha-firewall >/dev/null 2>&1  # (the rules are in place before Docker at every boot)
  python3 "${PROJECT_DIR}/ha/agent.py" firewall
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

function make_join_bundle() {
  # the configuration (same keys and passwords) and the cluster keys, for 'xpamctl ha join' on the other server
  local work
  work=$(mktemp -d)
  mkdir -p "${work}/ha"
  cp "${CONFIG_FILE}" "${work}/config.txt"
  cp -r "${HA_DIR}/certs" "${HA_DIR}/ssh" "${work}/ha/"
  (umask 077 && tar czf "${HA_DIR}/xpam-ha-join.tgz" -C "${work}" .)
  rm -rf "${work}"
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
  [[ -n "$(get_config HA_REWIND_PASSWORD)" ]] || set_config HA_REWIND_PASSWORD "$(random_str 32)"
  set_config HA_NODE_NAME xpam-a
  set_config HA_PEER_NAME xpam-b
  set_config HA_NODE_IP "${this}"
  set_config HA_PEER_IP "${peer}"
  set_config HA_WITNESS_IP "${witness}"
  # the vote starts with this server and the witness; 'ha join' adds the second server as a member
  # (etcd settles its cluster version only once every initial member has run)
  set_config HA_ETCD_CLUSTER "xpam-a=https://${this}:2380,xpam-witness=https://${witness}:2380"
  set_config HA_ETCD_STATE new

  # 2. the replication and rewind accounts (passwords from the environment, never on a command line)
  local db_user db_name
  db_user=$(get_config DB_USER); db_name=$(get_config DB_NAME)
  HA_RP="$(get_config HA_REPL_PASSWORD)" HA_WP="$(get_config HA_REWIND_PASSWORD)" docker exec -i -e HA_RP -e HA_WP xpam_postgresql \
    psql -v ON_ERROR_STOP=1 -U "${db_user}" -d "${db_name}" -q <<'SQL' || { log_error "The replication user could not be created"; return 1; }
\set rp `printenv HA_RP`
SELECT format('CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD %L', :'rp')
  WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') \gexec
SELECT format('ALTER ROLE replicator WITH REPLICATION LOGIN PASSWORD %L', :'rp') \gexec
\set wp `printenv HA_WP`
SELECT format('CREATE ROLE xpam_rewind WITH LOGIN PASSWORD %L', :'wp')
  WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'xpam_rewind') \gexec
SELECT format('ALTER ROLE xpam_rewind WITH LOGIN NOSUPERUSER PASSWORD %L', :'wp') \gexec
GRANT EXECUTE ON FUNCTION pg_catalog.pg_ls_dir(text, boolean, boolean) TO xpam_rewind;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_stat_file(text, boolean) TO xpam_rewind;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text) TO xpam_rewind;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean) TO xpam_rewind;
SQL

  # 3. bundles: the witness gets only the certificates; the other server gets the configuration
  local work
  work=$(mktemp -d)
  mkdir -p "${work}/witness/certs"
  cp "${HA_DIR}/certs/ca.crt" "${HA_DIR}/certs/node.crt" "${HA_DIR}/certs/node.key" "${work}/witness/certs/"
  sed -e "s#@THIS@#${witness}#g" -e "s#@CLUSTER@#$(get_config HA_ETCD_CLUSTER)#g" -e "s#@STATE@#new#g" \
      -e "s#@ALLOWED@#${this} ${peer}#g" "${PROJECT_DIR}/ha/witness.sh.in" > "${work}/witness/witness.sh"
  chmod 700 "${work}/witness/witness.sh"
  tar czf "${HA_DIR}/xpam-ha-witness.tgz" -C "${work}/witness" .
  rm -rf "${work}"
  make_join_bundle

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
      bash -c '[[ $(curl -s -o /dev/null -w "%{http_code}" --max-time 5 --cacert "'"${HA_DIR}"'/certs/ca.crt" --cert "'"${HA_DIR}"'/certs/node.crt" --key "'"${HA_DIR}"'/certs/node.key" "https://'"${this}"':8008/primary") == 200 ]]'; then
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
  local this peer witness bundle_version this_name peer_name
  # the bundle comes from the other server: its "peer" is this server
  this=$(grep '^HA_PEER_IP=' "${work}/config.txt" | cut -d= -f2-)
  peer=$(grep '^HA_NODE_IP=' "${work}/config.txt" | cut -d= -f2-)
  this_name=$(grep '^HA_PEER_NAME=' "${work}/config.txt" | cut -d= -f2-)
  peer_name=$(grep '^HA_NODE_NAME=' "${work}/config.txt" | cut -d= -f2-)
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
  [[ -n "${volume_dir}" ]] && set_config VOLUME_DIR "${volume_dir}"
  [[ -n "${config_dir}" ]] && set_config CONFIG_DIR "${config_dir}"
  set_config HA_NODE_NAME "${this_name:-xpam-b}"
  set_config HA_PEER_NAME "${peer_name:-xpam-a}"
  set_config HA_NODE_IP "${this}"
  set_config HA_PEER_IP "${peer}"
  set_config HA_ENABLED 1
  rm -rf "${HA_DIR}" && mkdir -p "${HA_DIR}"
  cp -r "${work}/ha/certs" "${work}/ha/ssh" "${HA_DIR}/"
  rm -rf "${work}"
  echo_yellow "\nImages"
  pull_images || { log_error "The images are not available"; return 1; }
  echo_yellow "\nJoining the vote"
  local etcd_image members
  etcd_image="gcr.io/etcd-development/etcd:v3.5.21"
  etcdctl() {
    docker run --rm -v "${HA_DIR}/certs:/certs:ro" --entrypoint /usr/local/bin/etcdctl "${etcd_image}" \
      --endpoints "https://${peer}:2379,https://${witness}:2379" --cacert /certs/ca.crt --cert /certs/node.crt \
      --key /certs/node.key "$@"
  }
  members=$(etcdctl member list 2>&1) || { log_error "The vote (etcd) does not answer: ${members}"; return 1; }
  local old_id
  old_id=$(grep "https://${this}:2380" <<< "${members}" | cut -d, -f1 | tr -d ' ')
  if [[ -n "${old_id}" ]]; then
    # a rebuilt server: its old membership goes first (a member that lost its data must not vote again)
    etcdctl member remove "${old_id}" >/dev/null || { log_error "The old membership of this server could not be removed"; return 1; }
  fi
  local tries=0
  until etcdctl member add "${this_name:-xpam-b}" --peer-urls "https://${this}:2380" >/dev/null 2>&1; do
    tries=$((tries + 1))
    (( tries < 12 )) || { log_error "This server could not be added to the vote ('etcdctl member list' on the primary)"; return 1; }
    sleep 5  # (etcd accepts a new member only when the others have been connected for a few seconds)
  done
  # the vote's current members (the new one has no name until it starts)
  set_config HA_ETCD_CLUSTER "$(etcdctl member list -w simple | awk -F', ' -v me="${this_name:-xpam-b}" \
    '{n=$3; if (n=="") n=me; printf "%s%s=%s", (NR>1?",":""), n, $4}')"
  set_config HA_ETCD_STATE existing
  echo_yellow "\nCopying the database from the primary"
  $(db_cmd) up -d
  if ! wait_until 7200 "copying (large databases take a while)" \
      bash -c '[[ $(curl -s -o /dev/null -w "%{http_code}" --max-time 5 --cacert "'"${HA_DIR}"'/certs/ca.crt" --cert "'"${HA_DIR}"'/certs/node.crt" --key "'"${HA_DIR}"'/certs/node.key" "https://'"${this}"':8008/replica") == 200 ]]'; then
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
  code=$(patroni_write POST switchover "{\"leader\":\"${leader}\",\"candidate\":\"${candidate}\"}")
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
  code=$(patroni_write POST failover "{\"candidate\":\"$(get_config HA_NODE_NAME)\"}")
  [[ "${code}" == "200" ]] || { log_error "Failover refused (HTTP ${code}): 'docker logs xpam_postgresql'"; return 1; }
  echo_green "This server is the primary."
}

function ha_etcdctl() { # etcdctl against the vote, with this server's certificates
  docker run --rm -v "${HA_DIR}/certs:/certs:ro" --entrypoint /usr/local/bin/etcdctl gcr.io/etcd-development/etcd:v3.5.21 \
    --endpoints "https://$(get_config HA_NODE_IP):2379,https://$(get_config HA_PEER_IP):2379" \
    --cacert /certs/ca.crt --cert /certs/node.crt --key /certs/node.key "$@"
}

function ha_vip() { # <ip/prefix>|off — the floating address held by the primary (both servers)
  is_ha_enabled || { log_error "High availability is not enabled"; return 1; }
  local vip=$1 current dev
  if [[ "${vip}" == "off" ]]; then
    current=$(get_config HA_VIP)
    if [[ -n "${current}" ]]; then
      dev=$(get_config HA_VIP_DEV)
      [[ -n "${dev}" ]] || dev=$(ip -o -4 addr show | awk -v ip="$(get_config HA_NODE_IP)" '{split($4,a,"/"); if (a[1]==ip) print $2}')
      ip addr del "${current}" dev "${dev}" 2>/dev/null || true
    fi
    set_config HA_VIP ""
    echo "Floating address off on this server (run it on the other server too)."
    return 0
  fi
  python3 -c 'import ipaddress,sys; i=ipaddress.IPv4Interface(sys.argv[1]); assert "/" in sys.argv[1]' "${vip}" 2>/dev/null || {
    log_error "Give the address with its prefix, e.g. 10.0.0.100/24"; return 1; }
  set_config HA_VIP "${vip}"
  make_join_bundle
  echo "Floating address ${vip}: the primary holds it (set the same on the other server: xpamctl ha vip ${vip})."
}

function ha_join_bundle() {
  is_ha_enabled || { log_error "High availability is not enabled"; return 1; }
  make_join_bundle
  echo "Join bundle (holds XPAM's secrets: delete it after use): ${HA_DIR}/xpam-ha-join.tgz"
  echo "On the rebuilt server ($(get_config HA_PEER_IP)), after installing the same XPAM version: xpamctl ha join xpam-ha-join.tgz"
}

function ha_witness_bundle() { # a bundle for a replacement witness (same address)
  is_ha_enabled || { log_error "High availability is not enabled"; return 1; }
  local witness this peer members old_id cluster work
  witness=$(get_config HA_WITNESS_IP); this=$(get_config HA_NODE_IP); peer=$(get_config HA_PEER_IP)
  members=$(ha_etcdctl member list 2>&1) || { log_error "The vote does not answer: ${members}"; return 1; }
  old_id=$(grep "https://${witness}:2380" <<< "${members}" | cut -d, -f1 | tr -d ' ')
  if [[ -n "${old_id}" ]]; then
    ha_etcdctl member remove "${old_id}" >/dev/null || { log_error "The old witness could not be removed from the vote"; return 1; }
  fi
  ha_etcdctl member add xpam-witness --peer-urls "https://${witness}:2380" >/dev/null || { log_error "The witness could not be added to the vote"; return 1; }
  cluster=$(ha_etcdctl member list -w simple | awk -F', ' '{n=$3; u=$4; if (n=="") n="xpam-witness"; printf "%s%s=%s", (NR>1?",":""), n, u}')
  work=$(mktemp -d)
  mkdir -p "${work}/certs"
  cp "${HA_DIR}/certs/ca.crt" "${HA_DIR}/certs/node.crt" "${HA_DIR}/certs/node.key" "${work}/certs/"
  sed -e "s#@THIS@#${witness}#g" -e "s#@CLUSTER@#${cluster}#g" -e "s#@STATE@#existing#g" \
      -e "s#@ALLOWED@#${this} ${peer}#g" "${PROJECT_DIR}/ha/witness.sh.in" > "${work}/witness.sh"
  chmod 700 "${work}/witness.sh"
  (umask 077 && tar czf "${HA_DIR}/xpam-ha-witness.tgz" -C "${work}" .)
  rm -rf "${work}"
  echo "Replacement witness bundle: ${HA_DIR}/xpam-ha-witness.tgz"
  echo "On the new witness (${witness}): mkdir xpam-witness && tar xzf xpam-ha-witness.tgz -C xpam-witness && ./xpam-witness/witness.sh"
}

function ha_disable() {
  is_ha_enabled || { log_error "High availability is not enabled"; return 1; }
  local role peer_role assume=${1:-}
  role=$(ha_role)
  peer_role=$(patroni_code liveness "$(get_config HA_PEER_IP)")
  if [[ "${role}" == "primary" && "${peer_role}" == "200" ]]; then
    log_error "Run 'xpamctl ha disable' on the other server (the standby) first; then here."
    return 1
  fi
  echo_yellow "Leaving high availability on this server (${role})"
  if [[ "${role}" == "primary" ]]; then
    echo "  This server keeps XPAM and its data and runs alone again (a few minutes offline)."
  else
    echo "  This server stops; its copy of the database is kept aside (not used)."
  fi
  if [[ "${assume}" != "-y" ]]; then
    local confirm="n"
    read_from_input confirm "Continue?" "y/n" "${confirm}"
    [[ "${confirm}" == "y" ]] || return 1
  fi
  local volume_dir stamp cmd
  volume_dir=$(get_config VOLUME_DIR); stamp=$(date +%F_%H%M%S)
  if [[ "${role}" == "primary" ]]; then
    bash "${BASE_DIR}/5_db_backup.sh" || { log_error "Database backup failed: nothing was changed"; return 1; }
  fi
  systemctl disable --now xpam-ha >/dev/null 2>&1 || true
  systemctl disable xpam-ha-firewall >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/xpam-ha-firewall.service /etc/systemd/system/xpam-ha.service
  systemctl daemon-reload
  [[ -n "$(get_config HA_VIP)" ]] && ha_vip off >/dev/null
  cd "${PROJECT_DIR}" || return 1
  cmd=$(get_docker_compose_cmd_line)
  ${cmd} down
  # firewall rule and the other server's key
  for ports in 5432,8008,2379,2380,6379,6380 5432,8008,2379,2380,6379; do
    while iptables -D DOCKER-USER -p tcp -m multiport --dports "${ports}" -m conntrack \
        --ctorigdst "$(get_config HA_NODE_IP)" -j XPAM-HA 2>/dev/null; do :; done
  done
  iptables -F XPAM-HA 2>/dev/null; iptables -X XPAM-HA 2>/dev/null
  sed -i '/ xpam-ha$/d' /root/.ssh/authorized_keys 2>/dev/null || true
  if [[ "${role}" == "primary" ]]; then
    # PostgreSQL on its own again: Patroni's settings out (its TLS files exist only in the HA container)
    docker run --rm -v "${volume_dir}/postgresql/data:/d" --entrypoint sh postgres:16.15-bookworm -c \
      'cd /d && printf "include '"'"'postgresql.base.conf'"'"'\n" > postgresql.conf && chown postgres:postgres postgresql.conf &&
       rm -f standby.signal recovery.signal patroni.dynamic.json postgresql.conf.backup pg_hba.conf.backup pg_ident.conf.backup postgresql.base.conf.backup' \
      || { log_error "The database settings could not be restored"; return 1; }
    set_config HA_ENABLED 0
    start_xpam_and_wait
    echo_green "This server runs XPAM alone again. The other server and the witness can be removed."
  else
    mv "${volume_dir}/postgresql/data" "${volume_dir}/postgresql/data.ha-standby-${stamp}" 2>/dev/null || true
    set_config HA_ENABLED 0
    echo_green "This server left high availability and is stopped. Now run 'xpamctl ha disable' on the primary."
  fi
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
  [[ "$(patroni_write PATCH config "{\"pause\": ${value}}")" == 200 ]]
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
    vip) [[ $# -ge 1 ]] || { echo "usage: xpamctl ha vip <ip/prefix>|off"; return 2; }
         ha_vip "$1" ;;
    witness-bundle) ha_witness_bundle ;;
    join-bundle) ha_join_bundle ;;
    disable) ha_disable "$@" ;;
    pause) ha_pause "${1:-on}" ;;
    app-start) app_start ;;
    app-stop) app_stop ;;
    *) echo "usage: xpamctl ha init|join|status|switchover|failover|vip|join-bundle|witness-bundle|disable|role|pause"; return 2 ;;
  esac
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main "$@"
fi
