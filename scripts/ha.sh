#!/usr/bin/env bash
#
# XPAM high availability: two servers (one primary, one standby) and a witness.
#
#   xpamctl ha init                                             asks: active-passive or active-active, the servers
#   xpamctl ha init --topology active-passive|active-active --servers <ip>,<ip>[,...] [--witness <ip>]
#                   --vault-bundle <xpam-vault-OTHER.enc>[,...] [-y]
#                                                               on the current XPAM server (becomes primary);
#                                                               XPAM's secrets must be in Vault first (vault connect)
#                   active-passive: 2-5 servers (a witness with 2 or 4); active-active: 3 or 5 servers
#   xpamctl ha init <this-ip> <other-ip> <witness-ip> --vault-bundle <xpam-vault-OTHER.enc>   (two servers, as before)
#   xpamctl ha join <xpam-ha-join-IP.enc> [-y]                  on every other server, one after the other
#   (witness)  decrypt xpam-ha-witness.enc and run witness.sh   on the witness (Docker only)
#   xpamctl ha status                                           roles, replication, files, witness
#   xpamctl ha switchover                                       planned: the other server becomes primary
#   xpamctl ha upgrade [-y]                                     rolling upgrade, with this installer's version:
#                                                               the standby first, then on the primary (it hands
#                                                               XPAM to the upgraded standby, then upgrades itself)
#   xpamctl ha failover --force                                 emergency: make THIS server primary
#   xpamctl ha vip <ip/prefix>|off                              floating address held by the primary (both servers)
#   xpamctl ha witness-bundle                                   replace the witness (same address)
#   xpamctl ha disable [-y]                                     back to one server (standby first, then primary)
#   xpamctl ha join-bundle [<ip>] [--vault-bundle <f>]          a fresh join bundle (to rebuild that server)
#   xpamctl ha rotate-certs [--finish] / apply-certs <bundle>   replace the CA and every certificate
# Bundles are encrypted (bundle passphrase); the CA key is kept encrypted (cluster passphrase). For
# automation: XPAM_HA_BUNDLE_PASSPHRASE / XPAM_HA_PASSPHRASE in the environment.
#
# PostgreSQL runs under Patroni (automatic failover decided by a vote of the servers, and the witness with an
# even number of servers); the agent (systemd service xpam-ha) starts XPAM on the primary only (active-passive)
# or on every healthy server (active-active), and copies files between them.
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

# ---------------------------------------------------------------- secrets at rest

function passphrase_from() { # VAR "what": from the environment (automation), else typed (not shown)
  local var=$1 what=$2 value
  value="${!var:-}"
  if [[ -z "${value}" ]]; then
    read -r -s -p "${what}: " value </dev/tty; echo >&2
  fi
  printf '%s' "${value}"
}

function encrypt_dir() { # src-dir out-file — AES-256, key from the passphrase in HA_BUNDLE_PW (PBKDF2)
  tar czf - -C "$1" . | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -pass env:HA_BUNDLE_PW -out "$2"
}

function decrypt_to() { # file dest-dir — with the passphrase in HA_BUNDLE_PW
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass env:HA_BUNDLE_PW -in "$1" 2>/dev/null | tar xzf - -C "$2"
}

function protect_ca_key() { # dir — the CA key encrypted with the cluster passphrase (HA_CLUSTER_PW); no plain copy left
  if openssl pkey -in "$1/ca.key" -aes256 -passout env:HA_CLUSTER_PW -out "$1/ca.key.enc"; then
    shred -u "$1/ca.key" 2>/dev/null || rm -f "$1/ca.key"
  else
    log_error "The CA key could not be encrypted"; return 1
  fi
}

function ca_key_ok() { # the cluster passphrase (HA_CLUSTER_PW) opens the CA key
  openssl pkey -in "${HA_DIR}/certs/ca.key.enc" -passin env:HA_CLUSTER_PW -noout 2>/dev/null
}

function ha_etcdctl() { # [--root] args — etcdctl against the vote with this server's certificate
  # (--root: the vote's administrator account, password passed by name in the environment, never as an argument)
  local env=()
  if [[ "${1:-}" == "--root" ]]; then
    shift
    export ETCDCTL_USER="root:$(get_config HA_ETCD_ROOT_PASSWORD)"
    env=(-e ETCDCTL_USER)
  fi
  docker run --rm -i "${env[@]}" -v "${HA_DIR}/certs:/certs:ro" --entrypoint /usr/local/bin/etcdctl \
    gcr.io/etcd-development/etcd:v3.5.21 \
    --endpoints "${HA_ETCD_ENDPOINTS:-$(vote_endpoints)}" \
    --cacert /certs/ca.crt --cert /certs/node.crt --key /certs/node.key "$@"
  local code=$?
  unset ETCDCTL_USER
  return ${code}
}

function vote_endpoints() { # every member of the vote: the servers and the witness
  local s out=""
  for s in $(ha_servers) $(get_config HA_WITNESS_IP); do
    out+="${out:+,}https://${s}:2379"
  done
  echo "${out}"
}

function setup_vote_accounts() {
  # before PostgreSQL starts: XPAM's records (/xpam/) only for the account xpam-node (Patroni, with its
  # password); the witness's certificate gets no account (it votes, it cannot change the records)
  if ha_etcdctl --root auth status 2>/dev/null | grep -q 'Status: true'; then
    return 0
  fi
  get_config HA_ETCD_ROOT_PASSWORD | tr -d '\n' | ha_etcdctl user add root --interactive=false >/dev/null 2>&1 || true
  ha_etcdctl user grant-role root root >/dev/null 2>&1 || true
  ha_etcdctl role add xpam >/dev/null 2>&1 || true
  ha_etcdctl role grant-permission xpam --prefix=true readwrite /xpam/ >/dev/null || return 1
  get_config HA_ETCD_PASSWORD | tr -d '\n' | ha_etcdctl user add xpam-node --interactive=false >/dev/null 2>&1 || true
  ha_etcdctl user grant-role xpam-node xpam >/dev/null || return 1
  ha_etcdctl auth enable >/dev/null || return 1
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
  # failover: the containers straight away (their settings are those of the last full start); the full
  # `xpamctl start` (preparation steps) only when that is not enough
  local cmd
  cmd=$(app_cmd)
  cd "${PROJECT_DIR}" || return 1
  gen_safe_config >/dev/null
  ${cmd} up -d 2>/dev/null || bash "${PROJECT_DIR}/xpamctl.sh" start
}

function app_stop() {
  local cmd
  cmd=$(app_cmd)
  cd "${PROJECT_DIR}" || return 1
  ${cmd} stop
}

# ---------------------------------------------------------------- common steps

function ha_servers() { # every XPAM server (HA_SERVERS; two-server clusters of earlier versions: this one and HA_PEER_IP)
  local listed
  listed=$(get_config HA_SERVERS)
  if [[ -n "${listed}" ]]; then
    tr ',' ' ' <<< "${listed}"
  elif [[ "$(get_config HA_NODE_NAME)" == "xpam-b" ]]; then
    echo "$(get_config HA_PEER_IP) $(get_config HA_NODE_IP)"  # (in the order of the names: xpam-a, xpam-b)
  else
    echo "$(get_config HA_NODE_IP) $(get_config HA_PEER_IP)"
  fi
}

function ha_peers() { # the other XPAM servers
  local s me
  me=$(get_config HA_NODE_IP)
  for s in $(ha_servers); do
    [[ "${s}" != "${me}" ]] && printf '%s ' "${s}"
  done
  echo
}

function ha_topology() { # active-passive (one server serves users) | active-active (every server does)
  local t
  t=$(get_config HA_TOPOLOGY)
  echo "${t:-active-passive}"
}

function node_name() { # position in the list of servers (0..4) — the server's name in the cluster
  echo "xpam-$(cut -c$(( $1 + 1 )) <<< abcde)"
}

function install_app_certs() {
  # active-active: XPAM's containers log in to the other servers' database and Redis with the cluster's app
  # certificate (database and Redis logins only: the vote does not know its name)
  [[ "$(ha_topology)" == "active-active" ]] || return 0
  local d
  d="$(get_config CONFIG_DIR)/certs"
  mkdir -p "${d}/ha"
  cp "${HA_DIR}/certs/ca.crt" "${HA_DIR}/certs/app.crt" "${HA_DIR}/certs/app.key" "${d}/ha/" || return 1
  cp "${HA_DIR}/certs/ca.crt" "${d}/db_ca.pem"
  cp "${HA_DIR}/certs/app.crt" "${d}/db_client.crt"
  cp "${HA_DIR}/certs/app.key" "${d}/db_client.key"
  chmod 600 "${d}/ha/app.key" "${d}/db_client.key"
}

function install_agent() {
  local volume_dir authorized line from
  volume_dir=$(get_config VOLUME_DIR)
  from=$(ha_peers | xargs | tr ' ' ',')
  # the other servers may copy files into XPAM's data folder, nothing else
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  authorized=/root/.ssh/authorized_keys
  touch "${authorized}" && chmod 600 "${authorized}"
  sed -i '/ xpam-ha$/d' "${authorized}"
  line="from=\"${from}\",restrict,command=\"${PROJECT_DIR}/ha/rsync-only.sh ${volume_dir}/core/data\" $(cat "${HA_DIR}/ssh/id_ed25519.pub")"
  echo "${line}" >> "${authorized}"
  sed "s#/opt/xpam-installer#${PROJECT_DIR}#g" "${PROJECT_DIR}/ha/xpam-ha.service" > /etc/systemd/system/xpam-ha.service
  sed "s#/opt/xpam-installer#${PROJECT_DIR}#g" "${PROJECT_DIR}/ha/xpam-ha-firewall.service" > /etc/systemd/system/xpam-ha-firewall.service
  systemctl daemon-reload
  systemctl enable xpam-ha-firewall >/dev/null 2>&1  # (the rules are in place before Docker at every boot)
  python3 "${PROJECT_DIR}/ha/agent.py" firewall
  systemctl enable xpam-ha >/dev/null 2>&1
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

function join_bundle_path() { # ip
  echo "${HA_DIR}/xpam-ha-join-${1}.enc"
}

function make_join_bundle() { # ip — for 'xpamctl ha join' on that server: the configuration (same keys and
  # passwords) with its own address and name, the cluster certificates and its own Vault login; encrypted with
  # the bundle passphrase (HA_BUNDLE_PW); the CA key only encrypted
  local ip=$1 work i=0 s name=""
  for s in $(ha_servers); do
    [[ "${s}" == "${ip}" ]] && name=$(node_name "${i}")
    i=$((i + 1))
  done
  [[ -n "${name}" ]] || { log_error "${ip} is not one of the cluster's servers ($(ha_servers))"; return 1; }
  work=$(mktemp -d)
  mkdir -p "${work}/ha/certs"
  cp "${CONFIG_FILE}" "${work}/config.txt"
  sed -i -e '/^HA_NODE_IP=/d' -e '/^HA_NODE_NAME=/d' -e '/^HA_JOIN_PRIMARY=/d' -e '/^HA_SERVERS=/d' "${work}/config.txt"
  printf 'HA_NODE_IP=%s\nHA_NODE_NAME=%s\nHA_JOIN_PRIMARY=%s\nHA_SERVERS=%s\n' "${ip}" "${name}" "$(get_config HA_NODE_IP)" \
    "$(ha_servers | xargs | tr ' ' ',')" >> "${work}/config.txt"
  cp "${HA_DIR}"/certs/{ca.crt,ca.key.enc,node.crt,node.key,client.crt,client.key} "${work}/ha/certs/" || {
    rm -rf "${work}"; log_error "The cluster certificates are incomplete"; return 1; }
  for s in app.crt app.key witness.crt witness.key; do
    [[ -s "${HA_DIR}/certs/${s}" ]] && cp "${HA_DIR}/certs/${s}" "${work}/ha/certs/"
  done
  cp -r "${HA_DIR}/ssh" "${work}/ha/"
  if [[ -f "${HA_DIR}/peer-vault/vault.env" ]]; then  # (earlier versions: the one other server's login, directly)
    local t
    t=$(mktemp -d -p "${HA_DIR}")
    mv "${HA_DIR}"/peer-vault/* "${t}/" && mv "${t}" "${HA_DIR}/peer-vault/$(get_config HA_PEER_IP)"
  fi
  [[ -d "${HA_DIR}/peer-vault/${ip}" ]] && cp -r "${HA_DIR}/peer-vault/${ip}" "${work}/vault"  # (its own Vault login)
  (umask 077 && encrypt_dir "${work}" "$(join_bundle_path "${ip}")")
  rm -rf "${work}"
}

function make_witness_bundle() { # cluster state(new|existing|keep) — the witness's certificate only, encrypted
  local work
  work=$(mktemp -d)
  mkdir -p "${work}/certs"
  cp "${HA_DIR}/certs/ca.crt" "${work}/certs/ca.crt"
  cp "${HA_DIR}/certs/witness.crt" "${work}/certs/node.crt"
  cp "${HA_DIR}/certs/witness.key" "${work}/certs/node.key"
  sed -e "s#@THIS@#$(get_config HA_WITNESS_IP)#g" -e "s#@CLUSTER@#$1#g" -e "s#@STATE@#$2#g" \
      -e "s#@ALLOWED@#$(ha_servers | xargs)#g" "${PROJECT_DIR}/ha/witness.sh.in" > "${work}/witness.sh"
  chmod 700 "${work}/witness.sh"
  (umask 077 && encrypt_dir "${work}" "${HA_DIR}/xpam-ha-witness.enc")
  rm -rf "${work}"
}

function bundle_passphrase() { # sets HA_BUNDLE_PW (XPAM_HA_BUNDLE_PASSPHRASE or a new one, shown once)
  if [[ -n "${XPAM_HA_BUNDLE_PASSPHRASE:-}" ]]; then
    export HA_BUNDLE_PW="${XPAM_HA_BUNDLE_PASSPHRASE}"
  else
    export HA_BUNDLE_PW="$(random_str 24)"
    echo_yellow "Bundle passphrase (needed to open the bundles on the other machines): ${HA_BUNDLE_PW}"
  fi
}

WITNESS_UNPACK="mkdir -p xpam-witness && openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in xpam-ha-witness.enc | tar xz -C xpam-witness && ./xpam-witness/witness.sh"

function check_layout() { # topology count witness — the combinations that keep a majority of votes
  local topology=$1 count=$2 witness=$3
  case "${topology}" in
    active-passive)
      (( count >= 2 && count <= 5 )) || { log_error "Active-passive: 2 to 5 servers"; return 1; }
      if (( count % 2 == 0 )); then
        [[ -n "${witness}" ]] || { log_error "With ${count} servers a witness is needed (the votes must be an odd number)"; return 1; }
      else
        [[ -z "${witness}" ]] || { log_error "With ${count} servers no witness is needed (it would make the votes an even number)"; return 1; }
      fi ;;
    active-active)
      (( count == 3 || count == 5 )) || {
        log_error "Active-active: 3 or 5 servers (they vote among themselves, and a majority of them moves the database and Redis)"; return 1; }
      [[ -z "${witness}" ]] || { log_error "Active-active uses no witness (3 or 5 servers vote among themselves)"; return 1; } ;;
    *) log_error "Choose active-passive or active-active"; return 1 ;;
  esac
}

function ha_init_ask() { # the layout, asked (xpamctl ha init without options): sets ASK_TOPOLOGY, ASK_SERVERS, ASK_WITNESS
  local choice count i ip first
  echo_yellow "XPAM high availability"
  echo "How should the XPAM servers work together?"
  echo "  1) Active-passive: one server serves users; the others keep a live copy and take over by themselves"
  echo "     (2 to 5 servers; with 2 or 4 a small witness machine votes too)"
  echo "  2) Active-active: every server serves users at the same time, behind a load balancer"
  echo "     (3 or 5 servers; more capacity, and a failed server only drops its own users' sessions)"
  choice=1
  read_from_input choice "Choose" "1/2" "${choice}"
  case "${choice}" in
    1) ASK_TOPOLOGY=active-passive; count=2 ;;
    2) ASK_TOPOLOGY=active-active; count=3 ;;
    *) log_error "Choose 1 or 2"; return 1 ;;
  esac
  read_from_input count "How many XPAM servers, this one included?" "" "${count}"
  [[ "${count}" =~ ^[0-9]+$ ]] || { log_error "Not a number: ${count}"; return 1; }
  first=$(ip -o -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | cut -d' ' -f2)
  ASK_SERVERS=""
  for (( i = 1; i <= count; i++ )); do
    if (( i == 1 )); then
      ip=${first}
      read_from_input ip "Address of this server" "" "${ip}"
    else
      ip=""
      read_from_input ip "Address of server ${i}" "" ""
    fi
    ASK_SERVERS+="${ASK_SERVERS:+,}${ip}"
  done
  ASK_WITNESS=""
  if [[ "${ASK_TOPOLOGY}" == "active-passive" ]] && (( count % 2 == 0 )); then
    read_from_input ASK_WITNESS "Address of the witness (any small machine with Docker)" "" ""
  fi
  ASK_VAULT_BUNDLES=""
  if secrets_from_vault; then
    for ip in ${ASK_SERVERS//,/ }; do
      local_ip "${ip}" && continue
      local f="xpam-vault-${ip}.enc"
      read_from_input f "Vault bundle of ${ip} (from the Vault kit)" "" "${f}"
      ASK_VAULT_BUNDLES+="${ASK_VAULT_BUNDLES:+ }${f}"
    done
  fi
}

function read_peer_vault_bundles() { # peers... — each other server's own Vault login (from the Vault kit), by its role
  local vb f ip role peer
  mkdir -p "${HA_DIR}/peer-vault"; chmod 700 "${HA_DIR}/peer-vault"
  for f in ${HA_PEER_VAULT_BUNDLES:-}; do
    [[ -f "${f}" ]] || { log_error "Vault bundle not found: ${f}"; return 1; }
    vb=$(mktemp -d)
    XV_BUNDLE_PW="$(passphrase_from XPAM_VAULT_BUNDLE_PASSPHRASE "Vault bundle passphrase")" \
      bash -c 'openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass env:XV_BUNDLE_PW -in "$1" 2>/dev/null | tar xzf - -C "$2"' _ "${f}" "${vb}"
    role=$(grep '^VAULT_ROLE=' "${vb}/vault.env" 2>/dev/null | cut -d= -f2-)
    ip=""
    for peer in "$@"; do
      [[ "${role}" == "xpam-${peer//./-}" ]] && ip=${peer}
    done
    [[ -n "${ip}" ]] || { rm -rf "${vb}"; log_error "${f} is not the Vault bundle of one of the other servers (or a wrong passphrase)"; return 1; }
    rm -rf "${HA_DIR}/peer-vault/${ip}"; mv "${vb}" "${HA_DIR}/peer-vault/${ip}"
  done
  chmod -R go-rwx "${HA_DIR}/peer-vault"
  for peer in "$@"; do
    [[ -d "${HA_DIR}/peer-vault/${peer}" ]] || {
      log_error "Give the Vault bundle of ${peer}: --vault-bundle xpam-vault-${peer}.enc (from the Vault kit: init --xpam <all servers>, or add-xpam ${peer})"; return 1; }
  done
}

# ---------------------------------------------------------------- init (first server)

function ha_init() { # topology servers(comma separated, this one among them) witness("" for none) [-y]
  local topology=$1 servers_csv=$2 witness=$3 assume=${4:-}
  local this="" s count i=0 name="" peers=() list=()
  if is_ha_enabled; then
    log_error "High availability is already enabled on this server (xpamctl ha status)"
    return 1
  fi
  IFS=',' read -r -a list <<< "${servers_csv}"
  count=${#list[@]}
  for s in "${list[@]}" ${witness}; do
    valid_ip "${s}" || { log_error "Not an IPv4 address: ${s}"; return 1; }
  done
  [[ -z "$(printf '%s\n' "${list[@]}" ${witness} | sort | uniq -d)" ]] || { log_error "The addresses must be different"; return 1; }
  for s in "${list[@]}"; do
    if local_ip "${s}"; then
      this=${s}; name=$(node_name "${i}")
    else
      peers+=("${s}")
    fi
    i=$((i + 1))
  done
  [[ -n "${this}" ]] || { log_error "None of ${servers_csv} is an address of this server: run 'ha init' on one of them"; return 1; }
  check_layout "${topology}" "${count}" "${witness}" || return 1
  check_requirements || return 1
  docker ps --format '{{.Names}}' | grep -qx xpam_core || { log_error "XPAM must be running"; return 1; }
  # XPAM: the cluster's configuration holds every password — in high availability it lives in HashiCorp Vault
  # (the XPAM Vault kit); each other server gets its own Vault login through its join bundle
  if secrets_from_vault; then
    mkdir -p "${HA_DIR}" && rm -rf "${HA_DIR}/peer-vault"
    read_peer_vault_bundles "${peers[@]}" || return 1
  elif [[ "${XPAM_HA_ALLOW_NO_VAULT:-}" != "1" ]]; then
    log_error "High availability needs XPAM's secrets in HashiCorp Vault first (they are shared by every server): xpamctl vault connect <bundle> — see docs/VAULT.md"
    return 1
  fi

  echo_yellow "XPAM high availability: ${topology}, ${count} servers"
  echo "  this server  ${this}   (${name}; becomes the primary)"
  i=0
  for s in "${list[@]}"; do
    [[ "${s}" != "${this}" ]] && echo "  server       ${s}   ($(node_name "${i}"); install the same XPAM version there first)"
    i=$((i + 1))
  done
  [[ -n "${witness}" ]] && echo "  witness      ${witness}   (any small machine with Docker; votes, holds no data)"
  if [[ "${topology}" == "active-active" ]]; then
    echo "  Every server serves users: put a load balancer in front of them (health URL /api/health/)."
  fi
  echo "  XPAM is offline for a few minutes while the database is switched."
  if [[ "${assume}" != "-y" && "${ASSUME_YES:-}" != "1" ]]; then
    local confirm="n"
    read_from_input confirm "Continue?" "y/n" "${confirm}"
    [[ "${confirm}" == "y" ]] || return 1
  fi

  # 1. secrets, certificates and keys (kept when init is run again)
  umask 077
  mkdir -p "${HA_DIR}/ssh"
  if [[ ! -s "${HA_DIR}/certs/ca.key.enc" ]]; then
    rm -rf "${HA_DIR}/certs"
    bash "${PROJECT_DIR}/ha/certs.sh" "${HA_DIR}/certs" --servers "${servers_csv}" ${witness:+--witness "${witness}"} || return 1
    if [[ -n "${XPAM_HA_PASSPHRASE:-}" ]]; then
      export HA_CLUSTER_PW="${XPAM_HA_PASSPHRASE}"
    else
      export HA_CLUSTER_PW="$(random_str 32)"
      echo_yellow "Cluster passphrase (keep it in your password safe: needed to replace the certificates): ${HA_CLUSTER_PW}"
    fi
    protect_ca_key "${HA_DIR}/certs" || return 1
  fi
  [[ -s "${HA_DIR}/ssh/id_ed25519" ]] || ssh-keygen -q -t ed25519 -N '' -C xpam-ha -f "${HA_DIR}/ssh/id_ed25519"
  [[ -n "$(get_config HA_ETCD_PASSWORD)" ]] || set_config HA_ETCD_PASSWORD "$(random_str 32)"
  [[ -n "$(get_config HA_ETCD_ROOT_PASSWORD)" ]] || set_config HA_ETCD_ROOT_PASSWORD "$(random_str 32)"
  [[ -n "$(get_config HA_REPL_PASSWORD)" ]] || set_config HA_REPL_PASSWORD "$(random_str 32)"
  [[ -n "$(get_config HA_PATRONI_PASSWORD)" ]] || set_config HA_PATRONI_PASSWORD "$(random_str 32)"
  [[ -n "$(get_config HA_REWIND_PASSWORD)" ]] || set_config HA_REWIND_PASSWORD "$(random_str 32)"
  set_config HA_TOPOLOGY "${topology}"
  set_config HA_SERVERS "${servers_csv}"
  set_config HA_NODE_NAME "${name}"
  set_config HA_NODE_IP "${this}"
  set_config HA_PEER_IP "${peers[0]}"  # (tools of earlier versions)
  set_config HA_WITNESS_IP "${witness}"
  if [[ "${topology}" == "active-active" ]]; then
    set_config HA_SENTINEL_HOSTS "xpam/$(printf '%s:26380,' "${list[@]}" | sed 's/,$//')"
    set_config HA_REDIS_MASTER "${this}"
    set_config HA_SENTINEL_QUORUM "$(( count / 2 + 1 ))"
  fi
  # the vote starts with this server (and the witness); 'ha join' adds every other server as a member
  # (etcd settles its cluster version only once every initial member has run)
  set_config HA_ETCD_CLUSTER "${name}=https://${this}:2380${witness:+,xpam-witness=https://${witness}:2380}"
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

  # 3. bundles (encrypted): the witness gets only its certificate; every other server its configuration
  bundle_passphrase
  if [[ -n "${witness}" ]]; then
    make_witness_bundle "$(get_config HA_ETCD_CLUSTER)" new || return 1
  fi
  for s in "${peers[@]}"; do
    make_join_bundle "${s}" || return 1
  done

  echo_green "\nPrepared. Now:"
  if [[ -n "${witness}" ]]; then
    echo "  1. witness ${witness}: copy ${HA_DIR}/xpam-ha-witness.enc there and run (it asks for the bundle passphrase):"
    echo "       ${WITNESS_UNPACK}"
    echo "  2. this server continues by itself as soon as the witness answers."
  fi
  echo "  afterwards, on each other server, one after the other: copy its bundle there and run 'xpamctl ha join <bundle>'"
  for s in "${peers[@]}"; do
    echo "       ${s}: $(join_bundle_path "${s}")"
  done
  echo
  if [[ -n "${witness}" ]]; then
    wait_until 3600 "waiting for the witness on ${witness}:2379" bash -c "exec 3<>/dev/tcp/${witness}/2379" 2>/dev/null || {
      log_error "The witness did not answer. Run 'xpamctl ha init' again when it runs."; return 1; }
  fi

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
  # the vote first, and its accounts before PostgreSQL starts
  $(db_cmd) up -d etcd
  export HA_ETCD_ENDPOINTS="https://${this}:2379${witness:+,https://${witness}:2379}"  # (the other servers are not there yet)
  vote_up() { ha_etcdctl endpoint health --cluster >/dev/null 2>&1; }
  wait_until 120 "waiting for the vote" vote_up || {
    log_error "The vote does not form ('docker logs xpam_etcd')"; return 1; }
  setup_vote_accounts || { log_error "The vote's accounts could not be set up"; return 1; }
  unset HA_ETCD_ENDPOINTS
  install_app_certs || { log_error "The cluster's app certificate could not be installed"; return 1; }
  rm -rf "$(get_config VOLUME_DIR)/redis/sentinel"  # (a Sentinel's state from an earlier cluster)
  $(db_cmd) up -d
  if ! wait_until 300 "waiting for PostgreSQL under Patroni to become primary" \
      bash -c '[[ $(curl -s -o /dev/null -w "%{http_code}" --max-time 5 --cacert "'"${HA_DIR}"'/certs/ca.crt" --cert "'"${HA_DIR}"'/certs/node.crt" --key "'"${HA_DIR}"'/certs/node.key" "https://'"${this}"':8008/primary") == 200 ]]'; then
    log_error "PostgreSQL did not become primary: 'docker logs xpam_postgresql'. To go back: set HA_ENABLED=0 in config.txt and xpamctl start"
    return 1
  fi
  install_agent
  wait_until 600 "waiting for XPAM to start" bash -c 'docker ps --format "{{.Names}} {{.Status}}" | grep -q "^xpam_core .*(healthy)"' || true
  echo_green "\nThis server is the primary. Next: 'xpamctl ha join <bundle>' on each other server ($(printf '%s ' "${peers[@]}"))."
}

# ---------------------------------------------------------------- join (every other server)

function ha_join() {
  local bundle=$1 assume=${2:-}
  [[ -f "${bundle}" ]] || { log_error "Bundle not found: ${bundle}"; return 1; }
  if is_ha_enabled; then
    log_error "High availability is already enabled on this server"; return 1
  fi
  check_requirements || return 1
  local work
  work=$(mktemp -d)
  export HA_BUNDLE_PW="$(passphrase_from XPAM_HA_BUNDLE_PASSPHRASE "Bundle passphrase")"
  decrypt_to "${bundle}" "${work}" && [[ -f "${work}/config.txt" && -s "${work}/ha/certs/node.crt" ]] || {
    rm -rf "${work}"; log_error "Not an XPAM high availability bundle, or a wrong passphrase"; return 1; }
  local this name primary witness bundle_version topology
  # the bundle is this server's: its address and name, and the primary it joins
  this=$(grep '^HA_NODE_IP=' "${work}/config.txt" | tail -1 | cut -d= -f2-)
  name=$(grep '^HA_NODE_NAME=' "${work}/config.txt" | tail -1 | cut -d= -f2-)
  primary=$(grep '^HA_JOIN_PRIMARY=' "${work}/config.txt" | tail -1 | cut -d= -f2-)
  witness=$(grep '^HA_WITNESS_IP=' "${work}/config.txt" | tail -1 | cut -d= -f2-)
  topology=$(grep '^HA_TOPOLOGY=' "${work}/config.txt" | tail -1 | cut -d= -f2-)
  bundle_version=$(grep '^CURRENT_VERSION=' "${work}/config.txt" | cut -d= -f2-)
  [[ -n "${primary}" ]] || { log_error "This bundle comes from an earlier version: make a new one on the primary (xpamctl ha join-bundle)"; rm -rf "${work}"; return 1; }
  local_ip "${this}" || { log_error "This bundle is for ${this}, not for this server"; rm -rf "${work}"; return 1; }
  if [[ -n "${bundle_version}" && "${bundle_version}" != "$(get_config CURRENT_VERSION)" ]]; then
    log_error "The primary runs ${bundle_version}, this server $(get_config CURRENT_VERSION): install the same version first"
    rm -rf "${work}"; return 1
  fi
  echo_yellow "XPAM high availability (${topology:-active-passive}): this server (${this}, ${name}) joins the cluster of ${primary}"
  echo "  This server's own XPAM data is replaced by the cluster's (its database is kept aside)."
  if [[ "${assume}" != "-y" ]]; then
    local confirm="n"
    read_from_input confirm "Continue?" "y/n" "${confirm}"
    [[ "${confirm}" == "y" ]] || { rm -rf "${work}"; return 1; }
  fi
  bash -c "exec 3<>/dev/tcp/${primary}/8008" 2>/dev/null || { log_error "The primary ${primary} is not reachable on port 8008"; rm -rf "${work}"; return 1; }

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
  # the cluster's configuration (same keys and passwords), with this server's own address, name and paths
  cp "${work}/config.txt" "${CONFIG_FILE}"
  [[ -n "${volume_dir}" ]] && set_config VOLUME_DIR "${volume_dir}"
  [[ -n "${config_dir}" ]] && set_config CONFIG_DIR "${config_dir}"
  set_config HA_PEER_IP "${primary}"  # (tools of earlier versions: the server joined)
  set_config HA_ENABLED 1
  gen_safe_config >/dev/null  # (the components' shared config follows the cluster's)
  rm -rf "${HA_DIR}" && mkdir -p "${HA_DIR}"
  cp -r "${work}/ha/certs" "${work}/ha/ssh" "${HA_DIR}/"
  if [[ -d "${work}/vault" ]]; then
    # XPAM: the passwords are in Vault — this server logs in with its own certificate and reads them into memory
    echo_yellow "\nVault (this server's own login)"
    bash "${BASE_DIR}/vault.sh" attach "${work}/vault" || { rm -rf "${work}"; log_error "This server cannot read XPAM's secrets from Vault"; return 1; }
  elif grep -q '^XPAM_SECRETS_FROM_VAULT=1' "${work}/config.txt"; then
    rm -rf "${work}"; log_error "The cluster keeps its secrets in Vault but the bundle has no Vault login for this server"; return 1
  fi
  rm -rf "${work}"
  echo_yellow "\nImages"
  pull_images || { log_error "The images are not available"; return 1; }
  echo_yellow "\nJoining the vote"
  local members
  export HA_ETCD_ENDPOINTS="https://${primary}:2379${witness:+,https://${witness}:2379}"
  etcdctl() { ha_etcdctl --root "$@"; }  # (adding a member needs the vote's administrator account)
  members=$(etcdctl member list 2>&1) || { log_error "The vote (etcd) does not answer: ${members}"; return 1; }
  local old_id
  old_id=$(grep "https://${this}:2380" <<< "${members}" | cut -d, -f1 | tr -d ' ')
  if [[ -n "${old_id}" ]]; then
    # a rebuilt server: its old membership goes first (a member that lost its data must not vote again)
    etcdctl member remove "${old_id}" >/dev/null || { log_error "The old membership of this server could not be removed"; return 1; }
  fi
  local tries=0 added member_id
  # a learner first: it receives the vote's data without counting, then becomes a voting member (the vote's
  # majority never depends on a server that is still starting)
  until added=$(etcdctl member add "${name}" --learner --peer-urls "https://${this}:2380" 2>&1); do
    tries=$((tries + 1))
    (( tries < 12 )) || { log_error "This server could not be added to the vote ('etcdctl member list' on the primary)"; return 1; }
    sleep 5  # (etcd accepts a new member only when the others have been connected for a few seconds)
  done
  member_id=$(grep -oE 'Member [0-9a-f]+' <<< "${added}" | awk '{print $2}' | head -1)
  # the vote's current members (the new one has no name until it starts)
  set_config HA_ETCD_CLUSTER "$(etcdctl member list -w simple | awk -F', ' -v me="${name}" \
    '{n=$3; if (n=="") n=me; printf "%s%s=%s", (NR>1?",":""), n, $4}')"
  set_config HA_ETCD_STATE existing
  install_app_certs || { log_error "The cluster's app certificate could not be installed"; return 1; }
  rm -rf "${volume_dir}/redis/sentinel"  # (a Sentinel's state from an earlier cluster)
  echo_yellow "\nCopying the database from the primary"
  $(db_cmd) up -d
  promote() { etcdctl member promote "${member_id}" >/dev/null 2>&1; }
  wait_until 300 "waiting for this server's vote to catch up" promote || {
    log_error "This server's vote did not catch up ('docker logs xpam_etcd'; 'etcdctl member list' on the primary)"; return 1; }
  unset HA_ETCD_ENDPOINTS
  if ! wait_until 7200 "copying (large databases take a while)" \
      bash -c '[[ $(curl -s -o /dev/null -w "%{http_code}" --max-time 5 --cacert "'"${HA_DIR}"'/certs/ca.crt" --cert "'"${HA_DIR}"'/certs/node.crt" --key "'"${HA_DIR}"'/certs/node.key" "https://'"${this}"':8008/replica") == 200 ]]'; then
    log_error "The database could not be copied: 'docker logs xpam_postgresql'"; return 1
  fi
  install_agent
  if [[ "${topology}" == "active-active" ]]; then
    echo_green "\nThis server is in the cluster: it serves users too (the agent starts XPAM here) and keeps a copy of the database."
  else
    echo_green "\nThis server is a standby: it follows the primary and takes over by itself if the primary fails."
  fi
  echo "Delete the bundle: shred -u ${bundle}"
}

# ---------------------------------------------------------------- operations

function ha_status() {
  is_ha_enabled || { echo "High availability is not enabled (xpamctl ha init)"; return 0; }
  local status witness
  witness=$(get_config HA_WITNESS_IP)
  echo_yellow "Cluster ($(ha_topology); servers $(ha_servers | xargs)${witness:+; witness ${witness}})"
  patroni cluster | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except ValueError:
    print("  Patroni is not answering on this server"); sys.exit()
for m in d.get("members", []):
    lag = m.get("lag", "")
    version = (m.get("tags") or {}).get("xpam_version") or "-"
    print("  %-8s %-15s %-13s %-10s lag %-6s XPAM %s" % (m["name"], m.get("host", ""), m["role"], m["state"],
                                                       lag if lag != "" else "-", version))'
  status="$(get_config VOLUME_DIR)/core/data/ha/status.json"
  if [[ -f "${status}" ]]; then
    echo_yellow "This server"
    python3 - "${status}" <<'PY'
import json, sys, time
s = json.load(open(sys.argv[1]))
fs = s.get('file_sync') or {}
age = int(time.time()) - int(s.get('updated') or 0)
print(f"  role {s['role']}, XPAM services {'running' if s['app_running'] else 'stopped'} (agent updated {age}s ago)")
peers = s.get('peers') or {}
if peers:
    print('  other servers: ' + ', '.join(f"{ip} {'reachable' if ok else 'NOT reachable'}" for ip, ok in peers.items()))
elif s.get('peer_reachable') is not None:
    print(f"  other server {'reachable' if s['peer_reachable'] else 'NOT reachable'}")
if s.get('witness_reachable') is not None:
    print(f"  witness {'reachable' if s['witness_reachable'] else 'NOT reachable'}")
if fs.get('time'):
    print(f"  file copy to the other servers: {'ok' if fs['ok'] else 'FAILED ' + fs.get('error', '')} ({int(time.time()) - fs['time']}s ago)")
PY
  fi
}

function ha_switchover() { # [candidate name] — another server's database becomes the primary
  is_ha_enabled || { log_error "High availability is not enabled"; return 1; }
  local leader candidate code
  leader=$(patroni cluster | python3 -c 'import json,sys; print(next((m["name"] for m in json.load(sys.stdin)["members"] if m["role"] in ("leader","standby_leader")), ""))')
  # (by default the synchronous standby: it has every committed change)
  candidate=${1:-$(patroni cluster | python3 -c '
import json, sys
ms = [m for m in json.load(sys.stdin)["members"] if m["state"] in ("streaming", "running")]
best = [m for m in ms if m["role"] == "sync_standby"] + [m for m in ms if m["role"] == "replica"]
print(best[0]["name"] if best else "")')}
  [[ -n "${leader}" && -n "${candidate}" ]] || { log_error "No healthy standby to switch to"; return 1; }
  echo "Switching the primary from ${leader} to ${candidate} (about a minute)"
  code=$(patroni_write POST switchover "{\"leader\":\"${leader}\",\"candidate\":\"${candidate}\"}")
  [[ "${code}" == "200" ]] || { log_error "Switchover refused (HTTP ${code}): the standby must be in sync ('xpamctl ha status')"; return 1; }
  echo_green "Done: ${candidate} is the primary."
}

function members_tsv() { # every member, from Patroni: name host role state lag version
  patroni cluster | python3 -c '
import json, sys
for m in json.load(sys.stdin).get("members", []):
    lag = m.get("lag", "")
    print(m["name"], m.get("host", "-"), m["role"], m["state"], lag if lag != "" else "-",
          (m.get("tags") or {}).get("xpam_version") or "-")'
}

function agent_status() { # field — from this server's agent (status.json)
  python3 - "$(get_config VOLUME_DIR)/core/data/ha/status.json" "$1" <<'PY' 2>/dev/null
import json, sys
s = json.load(open(sys.argv[1]))
v = s.get(sys.argv[2])
if sys.argv[2] == 'vault':
    nodes = (v or {}).get('nodes') or []
    v = 'none' if not nodes else ('ok' if all(n.get('state') == 'ok' for n in nodes) else
                                  ', '.join(f"{n['addr']} {n['state']}" for n in nodes if n.get('state') != 'ok'))
print('yes' if v is True else 'no' if v is False else v)
PY
}

function xpam_answers() { # host — XPAM's web answers there (the new primary after the switchover)
  curl -fsk --max-time 5 -o /dev/null "https://${1}:$(get_config HTTPS_PORT 443)/api/health/"
}

function ha_upgrade() { # [-y] — rolling upgrade to this installer's version: the other servers first, then the primary
  is_ha_enabled || { log_error "High availability is not enabled (plain 'xpamctl upgrade')"; return 1; }
  local assume=${1:-} target current role me members witness vault confirm="n" n h r st lag v bad pending
  target=${VERSION}
  current=$(get_config CURRENT_VERSION)
  role=$(ha_role)
  me=$(get_config HA_NODE_NAME)
  members=$(members_tsv)
  witness=$(agent_status witness_reachable)
  vault=$(agent_status vault)
  echo_yellow "Rolling upgrade to ${target} ($(ha_topology))"
  echo "  this server:  ${me}, ${role}, XPAM ${current:--}"
  while read -r n h r st lag v; do
    [[ -z "${n}" || "${n}" == "${me}" ]] || echo "  ${n}:      ${h} (${r}, ${st}, lag ${lag}, XPAM ${v})"
  done <<< "${members}"
  [[ -n "$(get_config HA_WITNESS_IP)" ]] && echo "  witness reachable: ${witness:-unknown}"
  echo "  Vault: ${vault:-unknown}"
  [[ "${role}" != "unknown" ]] || { log_error "Patroni does not answer on this server ('docker logs xpam_postgresql')"; return 1; }
  bad=$(awk -v me="${me}" 'NF && $1 != me && $4 != "running" && $4 != "streaming" {print $1}' <<< "${members}" | xargs)
  [[ -z "${bad}" && "$(grep -c . <<< "${members}")" -ge "$(ha_servers | wc -w)" ]] || {
    log_error "Not every server is running in the cluster${bad:+ (${bad})}: fix it first ('xpamctl ha status')"; return 1; }
  if [[ -n "$(get_config HA_WITNESS_IP)" ]]; then
    [[ "${witness}" == "yes" ]] || { log_error "The witness is not reachable: without it a failover cannot happen safely"; return 1; }
  fi
  [[ "${vault}" == "ok" || "${vault}" == "none" || -z "${vault}" ]] || {
    log_error "A Vault server is not healthy (${vault}): XPAM must read its secrets when it starts"; return 1; }
  # the other servers that do not have the new version yet (this one excepted)
  pending=$(awk -v me="${me}" -v t="${target}" 'NF && $1 != me && $3 != "leader" && $6 != t {print $2}' <<< "${members}" | xargs)

  if [[ "${role}" == "standby" ]]; then
    if [[ "${current}" == "${target}" ]]; then
      echo_green "This server is on ${target}."
    else
      echo
      if [[ "$(ha_topology)" == "active-active" ]]; then
        echo "Upgrades this server to ${target}. The other servers keep serving users; this one waits with the new"
        echo "version until the database has it (after the primary's turn)."
      else
        echo "Upgrades this server (a standby) to ${target}. XPAM keeps running on the primary."
      fi
      if [[ "${assume}" != "-y" ]]; then
        read_from_input confirm "Continue?" "y/n" "${confirm}"
        [[ "${confirm}" == "y" ]] || return 1
      fi
      AUTO_INSTALL=$([[ "${assume}" == "-y" ]] && echo 1 || echo "${AUTO_INSTALL:-0}") \
        bash "${BASE_DIR}/7_upgrade.sh" || { log_error "The upgrade of this server failed"; return 1; }
    fi
    if [[ -n "${pending}" ]]; then
      echo_yellow "Next, on each of: ${pending}: xpamctl ha upgrade"
    else
      echo_yellow "Next, on the primary ($(awk '$3 == "leader" {print $2}' <<< "${members}")): xpamctl ha upgrade"
    fi
    return 0
  fi

  # the primary
  if [[ "${current}" == "${target}" ]]; then
    [[ -z "${pending}" ]] && echo_green "Every server is on ${target}." \
      || echo_yellow "This server is on ${target}; now on each of: ${pending}: xpamctl ha upgrade"
    return 0
  fi
  if [[ -n "${pending}" ]]; then
    log_error "Upgrade the other servers first — on each of ${pending}: xpamctl ha upgrade (XPAM keeps running here meanwhile)"
    return 1
  fi
  local cand_name cand_host
  read -r cand_name cand_host < <(awk -v t="${target}" '$3 == "sync_standby" && $4 == "streaming" && $6 == t {print $1, $2; exit}' <<< "${members}")
  [[ -n "${cand_name}" ]] || read -r cand_name cand_host < <(awk -v t="${target}" '$3 == "replica" && $4 == "streaming" && $5 == "0" && $6 == t {print $1, $2; exit}' <<< "${members}")
  [[ -n "${cand_name}" ]] || { log_error "No other server on ${target} is in sync yet: wait, then run this again"; return 1; }
  echo
  echo "Every other server is on ${target}. Next:"
  echo "  1. the database's primary moves to ${cand_name} (${cand_host}), whose ${target} updates the database:"
  echo "     a short interruption while XPAM starts there"
  echo "  2. this server is upgraded to ${target}"
  echo "After step 1 the database has ${target}'s changes: going back to the old version means restoring the backup."
  if [[ "${assume}" != "-y" ]]; then
    read_from_input confirm "Continue?" "y/n" "${confirm}"
    [[ "${confirm}" == "y" ]] || return 1
  fi
  ha_switchover "${cand_name}" || return 1
  is_standby() { [[ "$(ha_role)" == "standby" ]]; }
  wait_until 180 "waiting for this server to become a standby" is_standby || {
    log_error "This server is still not a standby: check 'xpamctl ha status' before upgrading it"; return 1; }
  wait_until 900 "waiting for XPAM to answer on ${cand_host} (it updates the database)" xpam_answers "${cand_host}" || {
    log_error "XPAM does not answer on ${cand_host}: check it there ('docker logs xpam_core'); this server was not upgraded"
    return 1; }
  echo_green "XPAM ${target} runs on ${cand_host}. Upgrading this server (now a standby)."
  AUTO_INSTALL=$([[ "${assume}" == "-y" ]] && echo 1 || echo "${AUTO_INSTALL:-0}") \
    bash "${BASE_DIR}/7_upgrade.sh" || { log_error "The upgrade of this server failed (XPAM runs on ${cand_host})"; return 1; }
  echo_green "Every server is on ${target}; ${cand_host} is the primary ('xpamctl ha switchover' moves it again)."
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
  echo "Floating address ${vip}: the primary holds it (set the same on the other server: xpamctl ha vip ${vip})."
}

function ha_join_bundle() { # [ip] [--vault-bundle <file>] — a fresh join bundle for that server (to rebuild it)
  is_ha_enabled || { log_error "High availability is not enabled"; return 1; }
  local ip="" peers a
  read -r -a peers <<< "$(ha_peers)"
  while [[ $# -gt 0 ]]; do
    a=$1; shift
    if [[ "${a}" == "--vault-bundle" ]]; then export HA_PEER_VAULT_BUNDLES=$1; shift; else ip=${a}; fi
  done
  if [[ -z "${ip}" ]]; then
    (( ${#peers[@]} == 1 )) || { log_error "Which server? xpamctl ha join-bundle <ip> (one of: ${peers[*]})"; return 1; }
    ip=${peers[0]}
  fi
  if [[ -n "${HA_PEER_VAULT_BUNDLES:-}" ]]; then
    read_peer_vault_bundles "${ip}" || return 1
  elif secrets_from_vault && [[ ! -d "${HA_DIR}/peer-vault/${ip}" ]]; then
    log_error "This server has no Vault login for ${ip}: give its Vault bundle (--vault-bundle xpam-vault-${ip}.enc, from the Vault kit: add-xpam ${ip})"
    return 1
  fi
  bundle_passphrase
  make_join_bundle "${ip}" || return 1
  echo "Join bundle (encrypted): $(join_bundle_path "${ip}")"
  echo "On ${ip}, after installing the same XPAM version: xpamctl ha join $(basename "$(join_bundle_path "${ip}")")"
}

function ha_witness_bundle() { # a bundle for a replacement witness (same address)
  is_ha_enabled || { log_error "High availability is not enabled"; return 1; }
  local witness members old_id cluster
  witness=$(get_config HA_WITNESS_IP)
  [[ -n "${witness}" ]] || { log_error "This cluster has no witness (an odd number of servers votes on its own)"; return 1; }
  members=$(ha_etcdctl --root member list 2>&1) || { log_error "The vote does not answer: ${members}"; return 1; }
  old_id=$(grep "https://${witness}:2380" <<< "${members}" | cut -d, -f1 | tr -d ' ')
  if [[ -n "${old_id}" ]]; then
    ha_etcdctl --root member remove "${old_id}" >/dev/null || { log_error "The old witness could not be removed from the vote"; return 1; }
  fi
  ha_etcdctl --root member add xpam-witness --peer-urls "https://${witness}:2380" >/dev/null || { log_error "The witness could not be added to the vote"; return 1; }
  cluster=$(ha_etcdctl --root member list -w simple | awk -F', ' '{n=$3; u=$4; if (n=="") n="xpam-witness"; printf "%s%s=%s", (NR>1?",":""), n, u}')
  bundle_passphrase
  make_witness_bundle "${cluster}" existing || return 1
  echo "Replacement witness bundle (encrypted): ${HA_DIR}/xpam-ha-witness.enc"
  echo "On the new witness (${witness}): ${WITNESS_UNPACK}"
}

# ---------------------------------------------------------------- replacing every certificate

function apply_certs_local() {
  # take the certificates now in ${HA_DIR}/certs: the vote restarts (seconds), PostgreSQL, Patroni and
  # Redis re-read them without a restart (XPAM keeps running)
  docker restart xpam_etcd >/dev/null || return 1
  docker exec xpam_postgresql xpam-reload-certs >/dev/null || return 1
  docker exec xpam_redis sh -c 'cp /etc/xpam-ha/ca.crt /etc/xpam-ha/node.crt /etc/xpam-ha/node.key /tmp/xpam-tls/ && chown redis:redis /tmp/xpam-tls/*' || return 1
  local r
  for r in "tls-cert-file /tmp/xpam-tls/node.crt" "tls-key-file /tmp/xpam-tls/node.key" "tls-ca-cert-file /tmp/xpam-tls/ca.crt"; do
    # shellcheck disable=SC2086
    REDISCLI_AUTH="$(get_config REDIS_PASSWORD)" docker exec -e REDISCLI_AUTH xpam_redis redis-cli CONFIG SET ${r} >/dev/null || return 1
  done
  install_app_certs || return 1
  # (active-active: the Sentinel copies its certificates at start; its state is kept in its own file)
  if docker ps --format '{{.Names}}' | grep -qx xpam_sentinel; then
    docker restart xpam_sentinel >/dev/null || return 1
  fi
}

function install_certs() { # from-dir — keep the previous set aside, take the new one
  local stamp
  stamp=$(date +%F_%H%M%S)
  cp -a "${HA_DIR}/certs" "${HA_DIR}/certs.before-${stamp}"
  cp "$1"/{ca.crt,ca.key.enc,node.crt,node.key,client.crt,client.key} "${HA_DIR}/certs/" || return 1
  local f
  for f in app.crt app.key witness.crt witness.key; do
    [[ -s "$1/${f}" ]] && cp "$1/${f}" "${HA_DIR}/certs/"
  done
  chmod 600 "${HA_DIR}"/certs/*
}

function ha_rotate_certs() { # [--finish]
  is_ha_enabled || { log_error "High availability is not enabled"; return 1; }
  [[ "$(ha_role)" == "primary" ]] || { log_error "Run it on the primary"; return 1; }
  if [[ "${1:-}" == "--finish" ]]; then
    local lagging voters
    lagging=$(members_tsv | awk 'NF && $3 != "leader" && $4 != "streaming" {print $2}' | xargs)
    [[ -z "${lagging}" ]] || {
      log_error "Not following yet: ${lagging} (apply their bundles first: xpamctl ha apply-certs)"; return 1; }
    voters=$(( $(ha_servers | wc -w) + $([[ -n "$(get_config HA_WITNESS_IP)" ]] && echo 1 || echo 0) ))
    ha_etcdctl --root endpoint health --cluster 2>&1 | grep -c 'is healthy' | grep -qx "${voters}" || {
      log_error "The vote is not complete yet (every server, and the witness bundle on the witness)"; return 1; }
    ha_pause off || return 1
    echo_green "Done: every machine uses the new certificates; automatic failover is on again."
    return 0
  fi
  grep -q '"sync_standby"' <<< "$(patroni cluster)" || { log_error "A standby must be in sync first (xpamctl ha status)"; return 1; }
  export HA_CLUSTER_PW="$(passphrase_from XPAM_HA_PASSPHRASE "Cluster passphrase")"
  ca_key_ok || { log_error "Wrong cluster passphrase"; return 1; }
  echo_yellow "Replacing the CA and every certificate (XPAM keeps running; automatic failover is paused meanwhile)"
  local work cluster
  work=$(mktemp -d)
  local witness
  witness=$(get_config HA_WITNESS_IP)
  bash "${PROJECT_DIR}/ha/certs.sh" "${work}" --servers "$(ha_servers | xargs | tr ' ' ',')" ${witness:+--witness "${witness}"} || return 1
  protect_ca_key "${work}" || return 1
  ha_pause on || { log_error "Maintenance mode could not be turned on: nothing was changed"; rm -rf "${work}"; return 1; }
  cluster=$(ha_etcdctl --root member list -w simple | awk -F', ' '{printf "%s%s=%s", (NR>1?",":""), $3, $4}')
  install_certs "${work}" || return 1
  rm -rf "${work}"
  bundle_passphrase
  local p
  for p in $(ha_peers); do
    make_join_bundle "${p}" || return 1
  done
  [[ -n "${witness}" ]] && { make_witness_bundle "${cluster}" keep || return 1; }
  apply_certs_local || { log_error "The new certificates could not be applied here (the previous set is in ${HA_DIR}/certs.before-*)"; return 1; }
  echo_green "\nThis server uses the new certificates. Now:"
  for p in $(ha_peers); do
    echo "  - on ${p}: copy $(join_bundle_path "${p}") there and run: xpamctl ha apply-certs $(basename "$(join_bundle_path "${p}")")"
  done
  [[ -n "${witness}" ]] && echo "  - on the witness (${witness}): copy ${HA_DIR}/xpam-ha-witness.enc there and run: ${WITNESS_UNPACK}"
  echo "  then here: xpamctl ha rotate-certs --finish"
  if [[ "$(ha_topology)" == "active-active" ]]; then
    echo_yellow "  Active-active: until a server has applied its bundle, its XPAM cannot reach the database and Redis"
    echo_yellow "  (they now use the new CA): apply the bundles right away, one server after the other."
  fi
}

function ha_apply_certs() { # bundle — on the other server, after 'rotate-certs' on the primary
  is_ha_enabled || { log_error "High availability is not enabled"; return 1; }
  local bundle=$1 work
  [[ -f "${bundle}" ]] || { log_error "Bundle not found: ${bundle}"; return 1; }
  work=$(mktemp -d)
  export HA_BUNDLE_PW="$(passphrase_from XPAM_HA_BUNDLE_PASSPHRASE "Bundle passphrase")"
  decrypt_to "${bundle}" "${work}" && [[ -s "${work}/ha/certs/node.crt" ]] || {
    rm -rf "${work}"; log_error "Not an XPAM high availability bundle, or a wrong passphrase"; return 1; }
  install_certs "${work}/ha/certs" || { rm -rf "${work}"; return 1; }
  rm -rf "${work}"
  apply_certs_local || { log_error "The new certificates could not be applied"; return 1; }
  echo_green "This server uses the new certificates. Delete the bundle: rm -f ${bundle}"
}

function ha_disable() {
  is_ha_enabled || { log_error "High availability is not enabled"; return 1; }
  local role assume=${1:-} p still=""
  role=$(ha_role)
  if [[ "${role}" == "primary" ]]; then
    for p in $(ha_peers); do
      [[ "$(patroni_code liveness "${p}")" == "200" ]] && still+=" ${p}"
    done
    if [[ -n "${still}" ]]; then
      log_error "Run 'xpamctl ha disable' on the other servers first (still in the cluster:${still}); then here."
      return 1
    fi
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
  else
    # a server that is not the primary leaves only while another server runs (it might hold the last copy),
    # and leaves the vote too: the servers that stay keep their majority
    local alive="" member
    for p in $(ha_peers); do
      [[ "$(patroni_code liveness "${p}")" == "200" ]] && alive=1
    done
    [[ -n "${alive}" ]] || { log_error "No other server of the cluster is running: this one may hold the only copy of the database. Start another server first."; return 1; }
    member=$(ha_etcdctl --root member list 2>/dev/null | awk -F', ' -v u="https://$(get_config HA_NODE_IP):2380" '$4 == u {print $1}')
    if [[ -n "${member}" ]]; then
      ha_etcdctl --root member remove "${member}" >/dev/null || { log_error "This server could not leave the vote: nothing was changed"; return 1; }
    fi
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
  for ports in 5432,8008,2379,2380,6379,6380,26380 5432,8008,2379,2380,6379,6380 5432,8008,2379,2380,6379; do
    while iptables -D DOCKER-USER -p tcp -m multiport --dports "${ports}" -m conntrack \
        --ctorigdst "$(get_config HA_NODE_IP)" -j XPAM-HA 2>/dev/null; do :; done
  done
  iptables -F XPAM-HA 2>/dev/null; iptables -X XPAM-HA 2>/dev/null
  sed -i '/ xpam-ha$/d' /root/.ssh/authorized_keys 2>/dev/null || true
  # (active-active: XPAM's containers used the cluster's app certificate)
  rm -rf "${volume_dir}/redis/sentinel"
  rm -rf "$(get_config CONFIG_DIR)/certs/ha" "$(get_config CONFIG_DIR)/certs/db_ca.pem" \
    "$(get_config CONFIG_DIR)/certs/db_client.crt" "$(get_config CONFIG_DIR)/certs/db_client.key"
  if [[ "${role}" == "primary" ]]; then
    # PostgreSQL on its own again: Patroni's settings out (its TLS files exist only in the HA container)
    docker run --rm -v "${volume_dir}/postgresql/data:/d" --entrypoint sh postgres:16.15-bookworm -c \
      'cd /d && printf "include '"'"'postgresql.base.conf'"'"'\n" > postgresql.conf && chown postgres:postgres postgresql.conf &&
       rm -f standby.signal recovery.signal patroni.dynamic.json postgresql.conf.backup pg_hba.conf.backup pg_ident.conf.backup postgresql.base.conf.backup' \
      || { log_error "The database settings could not be restored"; return 1; }
    set_config HA_ENABLED 0
    set_config HA_TOPOLOGY ""
    start_xpam_and_wait
    echo_green "This server runs XPAM alone again. The other servers (and the witness) can be removed."
  else
    mv "${volume_dir}/postgresql/data" "${volume_dir}/postgresql/data.ha-standby-${stamp}" 2>/dev/null || true
    set_config HA_ENABLED 0
    set_config HA_TOPOLOGY ""
    echo_green "This server left high availability and is stopped. When every other server has, run 'xpamctl ha disable' on the primary."
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
    init) local topology="" servers="" witness="" assume="" pos=() a
          local usage="usage: xpamctl ha init [--topology active-passive|active-active] --servers <ip>,<ip>[,...] [--witness <ip>] --vault-bundle <xpam-vault-OTHER.enc>[,...] [-y]   (without options: asks)"
          HA_PEER_VAULT_BUNDLES=""
          while [[ $# -gt 0 ]]; do
            a=$1; shift
            case "${a}" in
              --topology) topology=$1; shift ;;
              --servers) servers=$1; shift ;;
              --witness) witness=$1; shift ;;
              --vault-bundle|--vault-bundles) HA_PEER_VAULT_BUNDLES+=" ${1//,/ }"; shift ;;
              -y) assume=-y ;;
              -*) echo "${usage}"; return 2 ;;
              *) pos+=("${a}") ;;
            esac
          done
          if (( ${#pos[@]} == 3 )); then  # (as before: this server, the other one and the witness)
            servers="${pos[0]},${pos[1]}"; witness=${pos[2]}
          elif (( ${#pos[@]} )); then
            echo "${usage}"; return 2
          fi
          if [[ -z "${servers}" ]]; then
            [[ "${assume}" != "-y" ]] || { echo "${usage}"; return 2; }
            ha_init_ask || return 1
            topology=${ASK_TOPOLOGY}; servers=${ASK_SERVERS}; witness=${ASK_WITNESS}
            HA_PEER_VAULT_BUNDLES+=" ${ASK_VAULT_BUNDLES}"
          fi
          export HA_PEER_VAULT_BUNDLES
          ha_init "${topology:-active-passive}" "${servers}" "${witness}" "${assume}" ;;
    join) [[ $# -ge 1 ]] || { echo "usage: xpamctl ha join <xpam-ha-join-IP.enc> [-y]"; return 2; }
          ha_join "$@" ;;
    status) ha_status ;;
    switchover) ha_switchover "$@" ;;
    upgrade) ha_upgrade "$@" ;;
    failover) ha_failover "$@" ;;
    role) ha_role ;;
    vip) [[ $# -ge 1 ]] || { echo "usage: xpamctl ha vip <ip/prefix>|off"; return 2; }
         ha_vip "$1" ;;
    witness-bundle) ha_witness_bundle ;;
    join-bundle) ha_join_bundle "$@" ;;
    rotate-certs) ha_rotate_certs "$@" ;;
    apply-certs) [[ $# -ge 1 ]] || { echo "usage: xpamctl ha apply-certs <xpam-ha-join-IP.enc>"; return 2; }
                 ha_apply_certs "$1" ;;
    disable) ha_disable "$@" ;;
    pause) ha_pause "${1:-on}" ;;
    app-start) app_start ;;
    app-stop) app_stop ;;
    *) echo "usage: xpamctl ha init|join|status|switchover|upgrade|failover|vip|join-bundle|witness-bundle|rotate-certs|apply-certs|disable|role|pause"; return 2 ;;
  esac
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main "$@"
fi
