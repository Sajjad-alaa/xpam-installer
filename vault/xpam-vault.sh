#!/usr/bin/env bash
#
# XPAM Vault kit: a hardened HashiCorp Vault cluster on its own servers, for XPAM.
#
#   xpam-vault.sh init --nodes IP1,IP2,IP3 --xpam IPA[,IPB] [options]   on the first Vault server
#   xpam-vault.sh join <xpam-vault-node-IP.enc>                           on the other Vault servers
#   xpam-vault.sh unseal                                                  after a Vault server (re)starts
#   xpam-vault.sh status                                                  seal state, cluster, audit
#   xpam-vault.sh add-xpam <ip>                                           a new XPAM server (bundle for it)
#   xpam-vault.sh snapshot <file>                                         backup of the cluster's data
#
# init options:
#   --admin-ips CIDR[,CIDR]   where Vault administrators connect from (default: the Vault servers)
#   --cluster NAME            name of the XPAM installation in Vault (default: xpam)
#   --siem HOST:PORT          also stream the audit log to a SIEM (TCP)
#   --pgp-keys F1,F2,...      encrypt each unseal key share to its holder (base64 of `gpg --export`)
#   --seal-config FILE        an auto-unseal "seal" stanza (Transit / cloud KMS / HSM) instead of key shares
#   --colocated               on XPAM's own three machines (high availability: both servers and the witness):
#                             each node unseals itself at boot; convenient, but root on an XPAM server is root
#                             on a Vault node (separate servers are stronger)
#   --local                   on the XPAM server itself (one address for --nodes and --xpam): XPAM's containers
#                             may connect (XPAM_DOCKER_SUBNET), unsealed at boot with systemd-creds (TPM2 when
#                             present). Weaker than separate servers: move later with `xpamctl vault connect`.
#
# What this sets up:
#   - Vault reachable only with a client certificate from the kit's CA, TLS 1.3 only; version, addresses
#     and cluster name are not revealed; no UI; the firewall allows 8200 only from XPAM, administrators and
#     the other Vault servers, and 8201 only between Vault servers.
#   - Raft storage replicated over 3 servers; each server runs Vault as a non-root user in a read-only
#     container without capabilities.
#   - Every request is written to the audit log (secret values only as HMAC); Vault refuses to answer when
#     no audit log can be written.
#   - XPAM logs in with its own client certificate; its token works only from its own address, lasts at
#     most an hour and may only use XPAM's two stores (no deletion of startup secrets' history).
#   - Administrators log in with the admin certificate; they can see the cluster's health, make backups and
#     recreate XPAM's logins, but cannot read XPAM's secrets or give themselves access (pinned values).
#   - No root token is kept; unseal key shares are shown once (or encrypted to their holders' PGP keys).
#
# Passphrases: the kit passphrase protects the CA key and the admin key on this server; the bundle
# passphrase opens the bundles for the other servers. Both are shown once. For automation:
# XPAM_VAULT_PASSPHRASE / XPAM_VAULT_BUNDLE_PASSPHRASE in the environment.
set -euo pipefail

VAULT_IMAGE="${XPAM_VAULT_IMAGE:-hashicorp/vault:2.1.2}"
BASE="${XPAM_VAULT_DIR:-/opt/xpam-vault}"
KEY_SHARES=5
KEY_THRESHOLD=3

red() { printf '\033[31m%s\033[0m\n' "$*" >&2; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
die() { red "ERROR: $*"; exit 1; }

valid_ip() { python3 -c 'import ipaddress,sys; ipaddress.IPv4Address(sys.argv[1])' "$1" 2>/dev/null; }
random_str() { head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "${1:-32}"; }
dashed() { echo "${1//./-}"; }

# a private scratch area in memory (tokens, decrypted keys); removed on exit
SCRATCH=""
scratch() {
  if [[ -z "${SCRATCH}" ]]; then
    SCRATCH=$(mktemp -d /dev/shm/xpam-vault.XXXXXX)
    chmod 700 "${SCRATCH}"
    trap 'rm -rf "${SCRATCH}"' EXIT
  fi
}

passphrase_from() { # VAR "what": from the environment (automation), else typed (not shown)
  local var=$1 what=$2 value
  value="${!var:-}"
  if [[ -z "${value}" ]]; then
    [[ -t 0 ]] || die "${what}: set ${var} or run interactively"
    read -r -s -p "  ${what}: " value; echo >&2
  fi
  [[ -n "${value}" ]] || die "${what} is empty"
  printf '%s' "${value}"
}

encrypt_dir() { # src-dir out-file — AES-256, PBKDF2; passphrase in XV_BUNDLE_PW
  tar czf - -C "$1" . | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -pass env:XV_BUNDLE_PW -out "$2"
  chmod 600 "$2"
}

decrypt_to() { # file dest-dir — passphrase in XV_BUNDLE_PW
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass env:XV_BUNDLE_PW -in "$1" 2>/dev/null | tar xzf - -C "$2"
}

# ---------------------------------------------------------------- certificates

gen_ca() { # dir — strict X.509 (accepted by Python 3.13+ VERIFY_X509_STRICT)
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
    -subj "/CN=XPAM Vault CA $(date +%Y%m%d%H%M%S)" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash" -keyout "$1/ca.key" -out "$1/ca.crt" 2>/dev/null
}

issue() { # dir name cn san eku — signed by dir/ca.key, 825 days
  local dir=$1 name=$2 cn=$3 san=$4 eku=$5
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=${cn}" \
    -keyout "${dir}/${name}.key" -out "${dir}/${name}.csr" 2>/dev/null
  printf 'basicConstraints=critical,CA:FALSE\nsubjectAltName=%s\nextendedKeyUsage=%s\nkeyUsage=critical,digitalSignature\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always\n' \
    "${san}" "${eku}" > "${dir}/${name}.ext"
  openssl x509 -req -in "${dir}/${name}.csr" -CA "${dir}/ca.crt" -CAkey "${dir}/ca.key" -CAcreateserial -days 825 \
    -extfile "${dir}/${name}.ext" -out "${dir}/${name}.crt" 2>/dev/null
  rm -f "${dir}/${name}.csr" "${dir}/${name}.ext" "${dir}/ca.srl"
}

ca_key_open() { # → SCRATCH/ca.key (kit passphrase)
  scratch
  XV_KIT_PW="$(passphrase_from XPAM_VAULT_PASSPHRASE "Kit passphrase")" \
    openssl pkey -in "${BASE}/kit/ca.key.enc" -passin env:XV_KIT_PW -out "${SCRATCH}/ca.key" 2>/dev/null \
    || die "wrong kit passphrase"
  cp "${BASE}/kit/ca.crt" "${SCRATCH}/ca.crt"
}

# ---------------------------------------------------------------- Vault API

load_env() { [[ -f "${BASE}/kit.env" ]] || die "not a Vault server of the kit (${BASE}/kit.env missing)"; . "${BASE}/kit.env"; }

api() { # method path [curl args...] — as this node (TLS only; add -H @token-file for a token)
  local m=$1 p=$2; shift 2
  curl -s --tlsv1.3 --max-time 30 --cacert "${BASE}/certs/ca.crt" --cert "${BASE}/certs/node.crt" --key "${BASE}/certs/node.key" \
    -X "$m" "https://${API_HOST:-${NODE_IP}}:8200/v1/${p}" "$@"
}

api_code() { # method path [curl args...] → HTTP status; body in SCRATCH/out
  scratch
  local m=$1 p=$2; shift 2
  api "$m" "$p" -o "${SCRATCH}/out" -w '%{http_code}' "$@"
}

json() { python3 -c 'import json,sys; d=json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d = d[int(k)] if isinstance(d, list) else d.get(k) if isinstance(d, dict) else None
print("" if d is None else (json.dumps(d) if isinstance(d, (dict, list)) else d))' "$1"; }

wait_api() { # wait until this node's API answers (sealed or not)
  local i
  for i in $(seq 1 60); do
    [[ "$(api_code GET sys/seal-status)" == 200 ]] && return 0
    sleep 2
  done
  die "Vault does not answer on ${NODE_IP}:8200 (docker logs xpam_vault)"
}

token_file() { # token → SCRATCH/token.hdr (header file: the token never appears on a command line)
  scratch
  printf 'X-Vault-Token: %s\n' "$1" > "${SCRATCH}/token.hdr"
  echo "${SCRATCH}/token.hdr"
}

admin_login() { # → header file with an admin token (admin certificate, kit passphrase)
  scratch
  XV_KIT_PW="$(passphrase_from XPAM_VAULT_PASSPHRASE "Kit passphrase")" \
    openssl pkey -in "${BASE}/kit/admin.key.enc" -passin env:XV_KIT_PW -out "${SCRATCH}/admin.key" 2>/dev/null \
    || die "wrong kit passphrase"
  local code
  code=$(curl -s --tlsv1.3 -o "${SCRATCH}/out" -w '%{http_code}' --max-time 30 --cacert "${BASE}/certs/ca.crt" \
    --cert "${BASE}/kit/admin.crt" --key "${SCRATCH}/admin.key" -X POST \
    "https://${NODE_IP}:8200/v1/auth/cert/login" -d '{"name":"vault-admin"}')
  [[ "${code}" == 200 ]] || die "admin login failed (${code}): $(cat "${SCRATCH}/out")"
  token_file "$(json auth.client_token < "${SCRATCH}/out")"
}

unseal_from_stdin_keys() { # reads key shares (one per line) from stdin, unseals this node
  local key code
  while IFS= read -r key; do
    [[ -n "${key}" ]] || continue
    code=$(printf '{"key":"%s"}' "${key}" | api_code PUT sys/unseal --data @-)
    [[ "${code}" == 200 ]] || die "unseal: $(cat "${SCRATCH}/out")"
    [[ "$(json sealed < "${SCRATCH}/out")" == "False" ]] && return 0
  done
  [[ "$(api GET sys/seal-status | json sealed)" == "False" ]]
}

# ---------------------------------------------------------------- files on a Vault server

write_server_files() { # writes vault.hcl, compose.yml, firewall from kit.env (NODE_IP, NODES, ...)
  load_env
  local peer seal=""
  [[ -f "${BASE}/seal.hcl" ]] && seal="$(cat "${BASE}/seal.hcl")"
  {
    cat <<EOF
# XPAM Vault kit — generated by xpam-vault.sh (do not edit by hand: re-run the kit)
ui                                  = false
disable_mlock                       = true
cluster_name                        = "xpam-vault"
api_addr                            = "https://${NODE_IP}:8200"
cluster_addr                        = "https://${NODE_IP}:8201"
default_lease_ttl                   = "1h"
max_lease_ttl                       = "24h"
raw_storage_endpoint                = false
introspection_endpoint              = false
enable_response_header_hostname     = false
enable_response_header_raft_node_id = false
log_level                           = "info"
log_format                          = "json"

listener "tcp" {
  address                            = "${NODE_IP}:8200"
  cluster_address                    = "${NODE_IP}:8201"
  tls_cert_file                      = "/vault/certs/node.crt"
  tls_key_file                       = "/vault/certs/node.key"
  tls_client_ca_file                 = "/vault/certs/ca.crt"
  tls_min_version                    = "tls13"
  tls_require_and_verify_client_cert = true
  redact_addresses                   = true
  redact_cluster_name                = true
  redact_version                     = true
  custom_response_headers {
    "default" = {
      "Strict-Transport-Security" = ["max-age=31536000; includeSubDomains"]
      "Cache-Control"             = ["no-store"]
    }
  }
}

storage "raft" {
  path    = "/vault/data"
  node_id = "vault-$(dashed "${NODE_IP}")"
EOF
    for peer in ${NODES//,/ }; do
      [[ "${peer}" == "${NODE_IP}" ]] && continue
      cat <<EOF
  retry_join {
    leader_api_addr         = "https://${peer}:8200"
    leader_ca_cert_file     = "/vault/certs/ca.crt"
    leader_client_cert_file = "/vault/certs/node.crt"
    leader_client_key_file  = "/vault/certs/node.key"
  }
EOF
    done
    echo "}"
    [[ -n "${seal}" ]] && printf '\n%s\n' "${seal}"
  } > "${BASE}/vault.hcl"

  cat > "${BASE}/compose.yml" <<EOF
# XPAM Vault kit — generated by xpam-vault.sh
services:
  vault:
    image: ${VAULT_IMAGE}
    container_name: xpam_vault
    command: server
    network_mode: host          # the firewall (chain XPAM-VAULT) decides who reaches 8200/8201
    user: "100:1000"            # the image's vault user, never root
    read_only: true
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    tmpfs: ["/tmp:size=16m,mode=1777"]
    ulimits:
      core: 0
      nofile: 65536
    environment:
      SKIP_SETCAP: "1"
      SKIP_CHOWN: "1"
    volumes:
      - ./vault.hcl:/vault/config/vault.hcl:ro
      - ./certs:/vault/certs:ro
      - ./data:/vault/data
      - ./logs:/vault/logs
    restart: unless-stopped
    logging:
      driver: json-file
      options: {max-size: "50m", max-file: "5"}
EOF

  cat > "${BASE}/firewall.sh" <<'EOF'
#!/usr/bin/env bash
# XPAM Vault kit: who may reach Vault (8200: XPAM, administrators, Vault servers; 8201: Vault servers)
set -e
. /opt/xpam-vault/kit.env
iptables -N XPAM-VAULT 2>/dev/null || true
iptables -F XPAM-VAULT
iptables -A XPAM-VAULT -i lo -j RETURN
for src in ${XPAM_IPS//,/ } ${XPAM_EXTRA_CIDRS//,/ } ${ADMIN_IPS//,/ } ${NODES//,/ }; do
  iptables -A XPAM-VAULT -p tcp --dport 8200 -s "${src}" -j RETURN
done
for src in ${NODES//,/ }; do
  iptables -A XPAM-VAULT -p tcp --dport 8201 -s "${src}" -j RETURN
done
iptables -A XPAM-VAULT -p tcp -m multiport --dports 8200,8201 -j DROP
iptables -C INPUT -j XPAM-VAULT 2>/dev/null || iptables -I INPUT 1 -j XPAM-VAULT
if command -v ip6tables >/dev/null; then
  ip6tables -C INPUT -p tcp -m multiport --dports 8200,8201 -j DROP 2>/dev/null \
    || ip6tables -I INPUT 1 -p tcp -m multiport --dports 8200,8201 -j DROP
fi
EOF
  sed -i "s#/opt/xpam-vault#${BASE}#" "${BASE}/firewall.sh"
  chmod 700 "${BASE}/firewall.sh"
}

install_server() { # files, firewall (now and at boot, before Docker), log rotation, container
  write_server_files
  mkdir -p "${BASE}/data" "${BASE}/logs"
  chown -R 100:1000 "${BASE}/certs" "${BASE}/data" "${BASE}/logs"
  chmod 750 "${BASE}/data" "${BASE}/logs"
  chmod 640 "${BASE}/certs/node.key"
  chmod 644 "${BASE}/vault.hcl" "${BASE}/compose.yml"
  if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
    cat > /etc/systemd/system/xpam-vault-firewall.service <<EOF
[Unit]
Description=XPAM Vault firewall (who may reach Vault)
Before=docker.service
After=network-pre.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${BASE}/firewall.sh
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable xpam-vault-firewall.service >/dev/null 2>&1 || true
  fi
  "${BASE}/firewall.sh"
  if [[ -d /etc/logrotate.d ]]; then
    cat > /etc/logrotate.d/xpam-vault <<EOF
${BASE}/logs/audit.log {
  daily
  rotate 90
  compress
  delaycompress
  missingok
  notifempty
  create 0600 100 1000
  postrotate
    docker kill -s HUP xpam_vault >/dev/null 2>&1 || true
  endscript
}
EOF
  fi
  docker compose -f "${BASE}/compose.yml" up -d >/dev/null
  wait_api
}

preflight() {
  command -v docker >/dev/null || die "Docker is required"
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required"
  command -v openssl >/dev/null && command -v curl >/dev/null && command -v python3 >/dev/null \
    || die "openssl, curl and python3 are required"
  if [[ "$(awk 'NR>1' /proc/swaps | wc -l)" -gt 0 && ( "${LOCAL:-0}" == 1 || "${COLOCATED:-0}" == 1 ) ]]; then
    yellow "  warning: swap is on: memory holding secrets could be written to disk (swapoff -a recommended)"
  elif [[ "$(awk 'NR>1' /proc/swaps | wc -l)" -gt 0 && "${XPAM_VAULT_ALLOW_SWAP:-}" != 1 ]]; then
    die "swap is on: Vault keeps secrets in memory, which must never be written to disk (swapoff -a and remove swap from /etc/fstab; XPAM_VAULT_ALLOW_SWAP=1 to override)"
  fi
  if command -v timedatectl >/dev/null && [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == no ]]; then
    yellow "  warning: the clock is not synchronized (NTP): certificates and tokens depend on it"
  fi
  [[ ! -e "${BASE}/kit.env" ]] || die "${BASE} is already set up"
}

# ---------------------------------------------------------------- policies

xpam_policy() { # cluster
  cat <<EOF
# XPAM ($1): account secrets in its own store
path "$1/data/orgs/*"         { capabilities = ["create", "read", "update", "patch", "delete"] }
path "$1/metadata/orgs/*"     { capabilities = ["create", "read", "update", "patch", "delete", "list"] }
# (the password history of accounts is kept under accounts/<id>/histories/)
path "$1/data/accounts/*"     { capabilities = ["create", "read", "update", "patch", "delete"] }
path "$1/metadata/accounts/*" { capabilities = ["create", "read", "update", "patch", "delete", "list"] }
# its startup secrets: read and write (rotation); never delete or destroy their history
path "$1-startup/data/config" { capabilities = ["create", "read", "update"] }
# its data key (Transit): encrypt, decrypt, re-wrap; see the key's versions; set when old versions stop
# opening anything and how often it rotates — never export, trim or delete it
path "$1-transit/encrypt/data" { capabilities = ["update"] }
path "$1-transit/decrypt/data" { capabilities = ["update"] }
path "$1-transit/rewrap/data"  { capabilities = ["update"] }
path "$1-transit/keys/data"    { capabilities = ["read"] }
path "$1-transit/keys/data/config" {
  capabilities = ["update"]
  allowed_parameters = {
    "min_decryption_version" = []
    "auto_rotate_period"     = []
  }
}
# its own token only
path "auth/token/lookup-self" { capabilities = ["read"] }
path "auth/token/renew-self"  { capabilities = ["update"] }
path "auth/token/revoke-self" { capabilities = ["update"] }
EOF
}

admin_policy() { # cluster ca-file xpam-cidrs-json
  cat <<EOF
# Vault administrators: health, backups, XPAM's logins (pinned values) — never XPAM's secrets
path "sys/storage/raft/configuration"   { capabilities = ["read"] }
path "sys/storage/raft/autopilot/state" { capabilities = ["read"] }
path "sys/storage/raft/snapshot"        { capabilities = ["read"] }
path "sys/audit"                        { capabilities = ["read", "sudo"] }
path "sys/mounts"                       { capabilities = ["read"] }
path "sys/auth"                         { capabilities = ["read"] }
path "sys/policies/acl"                 { capabilities = ["list"] }
path "sys/policies/acl/*"               { capabilities = ["read"] }
path "auth/cert/certs"                  { capabilities = ["list"] }
path "auth/cert/certs/xpam-*" {
  capabilities = ["create", "read", "update", "delete"]
  allowed_parameters = {
    "certificate"             = [$(python3 -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read()))' "$2")]
    "allowed_common_names"    = ["xpam-*"]
    "token_policies"          = ["$1"]
    "token_bound_cidrs"       = $3
    "token_no_default_policy" = [true]
    "token_type"              = ["service"]
    "display_name"            = []
    "token_ttl"               = []
    "token_max_ttl"           = []
  }
}
path "sys/leases/revoke-prefix/auth/cert/login" { capabilities = ["update", "sudo"] }
# the data key's versions and rotation (never encrypt or decrypt with it)
path "$1-transit/keys/data" { capabilities = ["read"] }
path "auth/token/lookup-self" { capabilities = ["read"] }
path "auth/token/renew-self"  { capabilities = ["update"] }
path "auth/token/revoke-self" { capabilities = ["update"] }
EOF
}

put_policy() { # hdr name text
  local code
  code=$(python3 -c 'import json,sys; print(json.dumps({"policy": sys.stdin.read()}))' <<< "$3" \
    | api_code PUT "sys/policies/acl/$2" -H @"$1" --data @-)
  [[ "${code}" == 204 ]] || die "policy $2: $(cat "${SCRATCH}/out")"
}

xpam_role() { # hdr ip — XPAM server login: its certificate, its address, 20 min tokens (max 1 h)
  local code
  code=$(python3 - "$2" "${CLUSTER}" "${BASE}/kit/ca.crt" "${XPAM_EXTRA_CIDRS:-}" <<'EOF' | api_code POST "auth/cert/certs/xpam-${2//./-}" -H @"$1" --data @-
import json, sys
ip, cluster, ca, extra = sys.argv[1:5]
cidrs = [ip + "/32"] + [c for c in extra.split(",") if c]
print(json.dumps({"display_name": "xpam-" + ip.replace(".", "-"), "certificate": open(ca).read(),
                  "allowed_common_names": ["xpam-" + ip.replace(".", "-")], "token_policies": [cluster],
                  "token_no_default_policy": True, "token_bound_cidrs": cidrs, "token_type": "service",
                  "token_ttl": "20m", "token_max_ttl": "1h"}))
EOF
)
  [[ "${code}" == 204 ]] || die "XPAM login for $2: $(cat "${SCRATCH}/out")"
}

# ---------------------------------------------------------------- bundles

xpam_bundle() { # ip — for an XPAM server: CA, its client certificate, the Vault addresses
  local ip=$1 d
  d=$(mktemp -d "${SCRATCH}/xb.XXXX")
  issue "${SCRATCH}" "xpam-${ip}" "xpam-$(dashed "${ip}")" "IP:${ip}" clientAuth
  cp "${BASE}/kit/ca.crt" "${d}/ca.crt"
  mv "${SCRATCH}/xpam-${ip}.crt" "${d}/client.crt"
  mv "${SCRATCH}/xpam-${ip}.key" "${d}/client.key"
  local addrs="" n
  for n in ${NODES//,/ }; do addrs="${addrs:+${addrs},}https://${n}:8200"; done
  cat > "${d}/vault.env" <<EOF
VAULT_ADDRS=${addrs}
VAULT_ROLE=xpam-$(dashed "${ip}")
VAULT_CLUSTER=${CLUSTER}
VAULT_ACCOUNT_MOUNT=${CLUSTER}
VAULT_STARTUP_PATH=${CLUSTER}-startup/data/config
VAULT_TRANSIT_MOUNT=${CLUSTER}-transit
EOF
  mkdir -p "${BASE}/out"
  encrypt_dir "${d}" "${BASE}/out/xpam-vault-${ip}.enc"
  rm -rf "${d}"
}

node_bundle() { # ip — for another Vault server: CA, its certificate, the kit settings
  local ip=$1 d
  d=$(mktemp -d "${SCRATCH}/nb.XXXX")
  issue "${SCRATCH}" "node-${ip}" "vault-$(dashed "${ip}")" "IP:${ip}" serverAuth,clientAuth
  mkdir -p "${d}/certs"
  cp "${BASE}/kit/ca.crt" "${d}/certs/ca.crt"
  mv "${SCRATCH}/node-${ip}.crt" "${d}/certs/node.crt"
  mv "${SCRATCH}/node-${ip}.key" "${d}/certs/node.key"
  sed "s/^NODE_IP=.*/NODE_IP=${ip}/" "${BASE}/kit.env" > "${d}/kit.env"
  [[ -f "${BASE}/seal.hcl" ]] && cp "${BASE}/seal.hcl" "${d}/seal.hcl"
  # co-located: the node unseals itself at boot with the shares, sealed there by its own systemd-creds
  [[ "${COLOCATED:-0}" == 1 && -s "${SCRATCH}/shares" ]] && head -n "${KEY_THRESHOLD}" "${SCRATCH}/shares" > "${d}/unseal.shares"
  mkdir -p "${BASE}/out"
  encrypt_dir "${d}" "${BASE}/out/xpam-vault-node-${ip}.enc"
  rm -rf "${d}"
}

bundle_passphrase() { # sets XV_BUNDLE_PW (XPAM_VAULT_BUNDLE_PASSPHRASE or a new one, shown once)
  if [[ -n "${XPAM_VAULT_BUNDLE_PASSPHRASE:-}" ]]; then
    export XV_BUNDLE_PW="${XPAM_VAULT_BUNDLE_PASSPHRASE}"
  else
    export XV_BUNDLE_PW="$(random_str 24)"
    yellow "Bundle passphrase (opens the bundles on the other servers): ${XV_BUNDLE_PW}"
  fi
}

# ---------------------------------------------------------------- commands

cmd_init() {
  local nodes="" xpam="" admin="" siem="" pgp="" seal_file="" extra=""
  CLUSTER=xpam; LOCAL=0; COLOCATED=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --nodes) nodes=$2; shift 2 ;;
      --xpam) xpam=$2; shift 2 ;;
      --admin-ips) admin=$2; shift 2 ;;
      --cluster) CLUSTER=$2; shift 2 ;;
      --siem) siem=$2; shift 2 ;;
      --pgp-keys) pgp=$2; shift 2 ;;
      --seal-config) seal_file=$2; shift 2 ;;
      --local) LOCAL=1; shift ;;
      --colocated) COLOCATED=1; shift ;;
      *) die "unknown option $1" ;;
    esac
  done
  [[ -n "${nodes}" && -n "${xpam}" ]] || die "usage: xpam-vault.sh init --nodes IP1,IP2,IP3 --xpam IPA[,IPB] [...]"
  [[ "${CLUSTER}" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || die "--cluster: lower-case letters, digits and dashes"
  local ip this=""
  for ip in ${nodes//,/ } ${xpam//,/ }; do valid_ip "${ip}" || die "not an IPv4 address: ${ip}"; done
  for ip in ${nodes//,/ }; do
    ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | grep -qx "${ip}" && this=${ip}
  done
  [[ -n "${this}" ]] || die "none of --nodes is an address of this server"
  if [[ "${LOCAL}" == 1 ]]; then
    # on the XPAM server itself: XPAM's containers connect from the Docker subnet; unsealed at boot by this server
    [[ "${nodes}" == "${xpam}" && "$(echo "${nodes//,/ }" | wc -w)" -eq 1 ]] || die "--local: one address, the same for --nodes and --xpam"
    extra="127.0.0.1/32${XPAM_DOCKER_SUBNET:+,${XPAM_DOCKER_SUBNET}}"
    command -v systemd-creds >/dev/null || die "--local needs systemd-creds (systemd 250+)"
  elif [[ "${COLOCATED}" == 1 ]]; then
    # on XPAM's own machines (high availability: A, B and the witness): XPAM's containers connect from the
    # Docker subnet; each node unseals itself at boot (systemd-creds) — no separation from XPAM's root
    [[ "$(echo "${nodes//,/ }" | wc -w)" -eq 3 ]] || die "--colocated: three nodes (the two XPAM servers and the witness)"
    extra="127.0.0.1/32${XPAM_DOCKER_SUBNET:+,${XPAM_DOCKER_SUBNET}}"
    [[ -n "${XPAM_DOCKER_SUBNET:-}" ]] || extra="127.0.0.1/32,192.168.250.0/24"
    command -v systemd-creds >/dev/null || die "--colocated needs systemd-creds (systemd 250+)"
  else
    [[ "$(echo "${nodes//,/ }" | wc -w)" -eq 3 ]] || yellow "  warning: 3 Vault servers are recommended (a majority must be up)"
  fi
  [[ -z "${seal_file}" || -f "${seal_file}" ]] || die "--seal-config: no such file"
  if [[ -n "${pgp}" ]]; then
    [[ "$(echo "${pgp//,/ }" | wc -w)" -eq "${KEY_SHARES}" ]] || die "--pgp-keys: give ${KEY_SHARES} key files (one per share holder)"
  fi
  preflight

  echo
  echo "  Vault servers  ${nodes}   (this one: ${this})"
  echo "  XPAM servers   ${xpam}"
  echo "  administrators ${admin:-the Vault servers}"
  echo
  mkdir -p "${BASE}/kit" "${BASE}/certs"
  chmod 700 "${BASE}" "${BASE}/kit"
  scratch

  # passphrases
  local kit_pw
  if [[ -n "${XPAM_VAULT_PASSPHRASE:-}" ]]; then kit_pw="${XPAM_VAULT_PASSPHRASE}"; else
    kit_pw="$(random_str 32)"
    yellow "Kit passphrase (keep it in your password safe: CA and admin key on this server): ${kit_pw}"
  fi
  bundle_passphrase

  # certificates: CA (key only encrypted), this server, the admin certificate
  gen_ca "${SCRATCH}"
  cp "${SCRATCH}/ca.crt" "${BASE}/kit/ca.crt"
  issue "${SCRATCH}" node "vault-$(dashed "${this}")" "IP:${this}" serverAuth,clientAuth
  issue "${SCRATCH}" admin vault-admin "DNS:vault-admin" clientAuth
  cp "${SCRATCH}/ca.crt" "${BASE}/certs/ca.crt"
  mv "${SCRATCH}/node.crt" "${BASE}/certs/node.crt"
  mv "${SCRATCH}/node.key" "${BASE}/certs/node.key"
  mv "${SCRATCH}/admin.crt" "${BASE}/kit/admin.crt"
  XV_KIT_PW="${kit_pw}" openssl pkey -in "${SCRATCH}/ca.key" -aes256 -passout env:XV_KIT_PW -out "${BASE}/kit/ca.key.enc"
  XV_KIT_PW="${kit_pw}" openssl pkey -in "${SCRATCH}/admin.key" -aes256 -passout env:XV_KIT_PW -out "${BASE}/kit/admin.key.enc"
  rm -f "${SCRATCH}/admin.key"
  chmod 600 "${BASE}/kit/"*

  cat > "${BASE}/kit.env" <<EOF
NODE_IP=${this}
NODES=${nodes}
XPAM_IPS=${xpam}
ADMIN_IPS=${admin}
CLUSTER=${CLUSTER}
LOCAL=${LOCAL}
COLOCATED=${COLOCATED}
XPAM_EXTRA_CIDRS=${extra}
EOF
  chmod 600 "${BASE}/kit.env"
  [[ -n "${seal_file}" ]] && cp "${seal_file}" "${BASE}/seal.hcl"

  echo "  1/4 starting Vault on this server"
  install_server

  echo "  2/4 initializing (key shares ${KEY_THRESHOLD} of ${KEY_SHARES})"
  local body code
  body=$(python3 - "${pgp}" "${seal_file}" "${KEY_SHARES}" "${KEY_THRESHOLD}" <<'EOF'
import json, sys
pgp, seal, shares, threshold = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
keys = [open(f).read().strip() for f in pgp.split(",")] if pgp else None
if seal:   # auto-unseal: recovery shares instead of unseal shares
    d = {"recovery_shares": shares, "recovery_threshold": threshold}
    if keys: d["recovery_pgp_keys"] = keys
else:
    d = {"secret_shares": shares, "secret_threshold": threshold}
    if keys: d["pgp_keys"] = keys
print(json.dumps(d))
EOF
)
  code=$(api_code PUT sys/init --data "${body}")
  [[ "${code}" == 200 ]] || die "init: $(cat "${SCRATCH}/out")"
  local root_token
  root_token=$(json root_token < "${SCRATCH}/out")
  python3 -c 'import json,sys; d=json.load(sys.stdin); print("\n".join(d.get("keys_base64") or d.get("recovery_keys_base64") or []))' \
    < "${SCRATCH}/out" > "${SCRATCH}/shares"
  rm -f "${SCRATCH}/out"
  if [[ -z "${seal_file}" ]]; then
    if [[ -n "${pgp}" ]]; then
      yellow "  (shares are PGP-encrypted: their holders decrypt them only to unseal)"
    else
      head -n "${KEY_THRESHOLD}" "${SCRATCH}/shares" | unseal_from_stdin_keys || die "unseal failed"
    fi
  fi
  local hdr; hdr=$(token_file "${root_token}")
  unset root_token
  [[ ( "${LOCAL}" == 1 || "${COLOCATED}" == 1 ) && -z "${seal_file}" ]] && install_local_unseal

  if [[ -n "${pgp}" && -z "${seal_file}" ]]; then
    echo
    yellow "  Unseal this server now (3 holders decrypt their share: gpg -d), then the setup continues."
    echo "  Encrypted shares:"; cat "${SCRATCH}/shares"; echo
    unseal_interactive
  fi
  local i
  for i in $(seq 1 30); do [[ "$(api GET sys/health -o /dev/null -w '%{http_code}')" == 200 ]] && break; sleep 2; done

  echo "  3/4 configuring: audit, XPAM's stores, policies, certificate logins"
  code=$(api_code PUT sys/audit/file -H @"${hdr}" \
    --data '{"type":"file","options":{"file_path":"/vault/logs/audit.log","mode":"0600"}}')
  [[ "${code}" == 204 ]] || die "audit: $(cat "${SCRATCH}/out")"
  if [[ -n "${siem}" ]]; then
    code=$(api_code PUT sys/audit/siem -H @"${hdr}" \
      --data "{\"type\":\"socket\",\"options\":{\"address\":\"${siem}\",\"socket_type\":\"tcp\"}}")
    [[ "${code}" == 204 ]] || die "SIEM audit: $(cat "${SCRATCH}/out")"
  fi
  code=$(api_code POST "sys/mounts/${CLUSTER}" -H @"${hdr}" \
    --data '{"type":"kv","options":{"version":"2"},"description":"XPAM account secrets"}')
  [[ "${code}" == 204 ]] || die "store: $(cat "${SCRATCH}/out")"
  code=$(api_code POST "sys/mounts/${CLUSTER}-startup" -H @"${hdr}" \
    --data '{"type":"kv","options":{"version":"2"},"description":"XPAM startup secrets"}')
  [[ "${code}" == 204 ]] || die "startup store: $(cat "${SCRATCH}/out")"
  # the data key: never leaves Vault, a derived key per value, rotated every 7 days (old versions still open
  # values until XPAM has re-wrapped them)
  code=$(api_code POST "sys/mounts/${CLUSTER}-transit" -H @"${hdr}" --data '{"type":"transit","description":"XPAM data key"}')
  [[ "${code}" == 204 ]] || die "transit: $(cat "${SCRATCH}/out")"
  code=$(api_code POST "${CLUSTER}-transit/keys/data" -H @"${hdr}" \
    --data '{"type":"aes256-gcm96","derived":true,"exportable":false,"allow_plaintext_backup":false,"auto_rotate_period":"168h"}')
  [[ "${code}" == 200 || "${code}" == 204 ]] || die "data key: $(cat "${SCRATCH}/out")"
  api_code POST "${CLUSTER}/config" -H @"${hdr}" --data '{"max_versions":20}' >/dev/null
  api_code POST "${CLUSTER}-startup/config" -H @"${hdr}" --data '{"max_versions":50}' >/dev/null

  put_policy "${hdr}" "${CLUSTER}" "$(xpam_policy "${CLUSTER}")"
  local cidrs
  cidrs=$(python3 -c 'import json,sys; print(json.dumps([i + "/32" for i in sys.argv[1].split(",")] + [c for c in sys.argv[2].split(",") if c]))' "${xpam}" "${extra}")
  put_policy "${hdr}" vault-admin "$(admin_policy "${CLUSTER}" "${BASE}/kit/ca.crt" "${cidrs}")"
  code=$(api_code POST sys/auth/cert -H @"${hdr}" --data '{"type":"cert","description":"client certificates (kit CA)"}')
  [[ "${code}" == 204 ]] || die "certificate login: $(cat "${SCRATCH}/out")"
  for ip in ${xpam//,/ }; do xpam_role "${hdr}" "${ip}"; done
  local admin_cidrs
  admin_cidrs=$(python3 -c 'import json,sys; print(json.dumps(sorted({c if "/" in c else c + "/32" for c in sys.argv[1].replace(",", " ").split()})))' \
    "${admin} ${nodes}")
  code=$(python3 - "${BASE}/kit/ca.crt" "${admin_cidrs}" <<'EOF' | api_code POST auth/cert/certs/vault-admin -H @"${hdr}" --data @-
import json, sys
print(json.dumps({"display_name": "vault-admin", "certificate": open(sys.argv[1]).read(),
                  "allowed_common_names": ["vault-admin"], "token_policies": ["vault-admin"],
                  "token_no_default_policy": True, "token_bound_cidrs": json.loads(sys.argv[2]),
                  "token_type": "service", "token_ttl": "15m", "token_max_ttl": "1h"}))
EOF
)
  [[ "${code}" == 204 ]] || die "admin login: $(cat "${SCRATCH}/out")"

  echo "  4/4 bundles for the other servers; revoking the root token"
  for ip in ${nodes//,/ }; do [[ "${ip}" == "${this}" ]] || node_bundle "${ip}"; done
  for ip in ${xpam//,/ }; do xpam_bundle "${ip}"; done
  api_code POST auth/token/revoke-self -H @"${hdr}" >/dev/null
  rm -f "${hdr}"

  echo
  if [[ -z "${seal_file}" && -z "${pgp}" ]]; then
    yellow "UNSEAL KEY SHARES — shown once. Give one to each of ${KEY_SHARES} different people; ${KEY_THRESHOLD} are needed"
    yellow "to unseal a Vault server after a restart, and to create a root token in an emergency:"
  elif [[ -n "${seal_file}" ]]; then
    yellow "RECOVERY KEY SHARES (auto-unseal) — shown once; ${KEY_THRESHOLD} of ${KEY_SHARES} are needed for an emergency root token:"
  fi
  if [[ -n "${XPAM_VAULT_SHARES_FILE:-}" ]]; then
    install -m 600 "${SCRATCH}/shares" "${XPAM_VAULT_SHARES_FILE}"; info "(written to ${XPAM_VAULT_SHARES_FILE})"
  elif [[ -z "${pgp}" ]]; then
    nl -w1 -s'. ' "${SCRATCH}/shares"
  fi
  rm -f "${SCRATCH}/shares"
  echo
  echo "  Next:"
  for ip in ${nodes//,/ }; do
    [[ "${ip}" == "${this}" ]] && continue
    echo "   - Vault server ${ip}: copy ${BASE}/out/xpam-vault-node-${ip}.enc and this script there and run:"
    echo "       xpam-vault.sh join xpam-vault-node-${ip}.enc     (then: xpam-vault.sh unseal)"
  done
  for ip in ${xpam//,/ }; do
    echo "   - XPAM server ${ip}: copy ${BASE}/out/xpam-vault-${ip}.enc there and run: xpamctl vault connect xpam-vault-${ip}.enc"
  done
  echo "   - delete the bundles from ${BASE}/out once copied"
}

install_local_unseal() { # --local: 3 key shares sealed with systemd-creds (TPM2 when present, else this host's key)
  mkdir -p /etc/xpam-vault; chmod 700 /etc/xpam-vault
  head -n "${KEY_THRESHOLD}" "${SCRATCH}/shares" | systemd-creds encrypt --name=xpam-vault-unseal - /etc/xpam-vault/unseal.cred \
    || die "systemd-creds could not seal the unseal key"
  chmod 600 /etc/xpam-vault/unseal.cred
  local kind="this server's own key (no TPM)"
  systemd-creds has-tpm2 >/dev/null 2>&1 && kind="the TPM"
  info "unsealed at every boot (key shares sealed with ${kind})"
  mkdir -p "${BASE}/bin"
  cp "$(readlink -f "${BASH_SOURCE[0]}")" "${BASE}/bin/xpam-vault.sh"
  chmod 700 "${BASE}/bin/xpam-vault.sh"
  printf '%s\n' '[Unit]' 'Description=XPAM local Vault: unseal at boot' 'After=docker.service' 'Requires=docker.service' '' \
    '[Service]' 'Type=simple' "ExecStart=/bin/bash ${BASE}/bin/xpam-vault.sh auto-unseal" 'Restart=on-failure' 'RestartSec=10' '' \
    '[Install]' 'WantedBy=multi-user.target' > /etc/systemd/system/xpam-vault-unseal.service
  systemctl daemon-reload
  systemctl enable xpam-vault-unseal.service >/dev/null 2>&1
}

cmd_auto_unseal() { # boot: wait for this Vault, unseal it with the sealed shares
  load_env; scratch
  local i
  for i in $(seq 1 600); do [[ "$(api_code GET sys/seal-status)" == 200 ]] && break; sleep 2; done
  [[ "$(api GET sys/seal-status | json sealed)" == "True" ]] || return 0
  systemd-creds decrypt --name=xpam-vault-unseal /etc/xpam-vault/unseal.cred - | unseal_from_stdin_keys || die "auto-unseal failed"
  info "unsealed"
}

unseal_interactive() { # asks for key shares until this node is unsealed (or reads them from stdin)
  local key code
  while [[ "$(api GET sys/seal-status | json sealed)" == "True" ]]; do
    if [[ -t 0 ]]; then read -r -s -p "  Unseal key share: " key; echo >&2; else IFS= read -r key || die "not enough key shares"; fi
    [[ -n "${key}" ]] || continue
    code=$(printf '{"key":"%s"}' "${key}" | api_code PUT sys/unseal --data @-)
    [[ "${code}" == 200 ]] || { red "  $(json errors.0 < "${SCRATCH}/out")"; continue; }
    [[ "$(json sealed < "${SCRATCH}/out")" == "False" ]] && break
    if [[ "$(json progress < "${SCRATCH}/out")" == 0 ]]; then
      # the threshold is reached: a server joining the cluster stays sealed until it has caught up
      info "key shares accepted; joining the cluster..."
      local i
      for i in $(seq 1 60); do [[ "$(api GET sys/seal-status | json sealed)" == "False" ]] && break; sleep 2; done
      break
    fi
    info "progress $(json progress < "${SCRATCH}/out")/$(json t < "${SCRATCH}/out")"
  done
  [[ "$(api GET sys/seal-status | json sealed)" == "False" ]] || die "still sealed"
  info "unsealed"
}

cmd_join() {
  local bundle=${1:-}
  [[ -f "${bundle}" ]] || die "usage: xpam-vault.sh join <xpam-vault-node-IP.enc>"
  preflight
  scratch
  export XV_BUNDLE_PW="$(passphrase_from XPAM_VAULT_BUNDLE_PASSPHRASE "Bundle passphrase")"
  local d; d=$(mktemp -d "${SCRATCH}/j.XXXX")
  decrypt_to "${bundle}" "${d}" && [[ -f "${d}/kit.env" ]] || die "wrong bundle passphrase (or not a node bundle)"
  . "${d}/kit.env"
  ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | grep -qx "${NODE_IP}" \
    || die "this bundle is for ${NODE_IP}, not for this server"
  mkdir -p "${BASE}"; chmod 700 "${BASE}"
  cp -r "${d}/certs" "${BASE}/certs"
  install -m 600 "${d}/kit.env" "${BASE}/kit.env"
  [[ -f "${d}/seal.hcl" ]] && cp "${d}/seal.hcl" "${BASE}/seal.hcl"
  echo "  starting Vault on ${NODE_IP} (it joins the cluster once unsealed)"
  install_server
  if [[ -s "${d}/unseal.shares" ]]; then
    cp "${d}/unseal.shares" "${SCRATCH}/shares"
    install_local_unseal
    rm -f "${SCRATCH}/shares"
    unseal_interactive < <(systemd-creds decrypt --name=xpam-vault-unseal /etc/xpam-vault/unseal.cred -)
    return 0
  fi
  if [[ -f "${BASE}/seal.hcl" ]]; then info "auto-unseal: nothing more to do"; else
    echo "  next: xpam-vault.sh unseal   (${KEY_THRESHOLD} key share holders)"
  fi
}

cmd_unseal() {
  load_env; scratch
  [[ "$(api GET sys/seal-status | json sealed)" == "True" ]] || { info "already unsealed"; return 0; }
  unseal_interactive
}

cmd_status() {
  load_env; scratch
  local n
  for n in ${NODES//,/ }; do
    printf '  %-16s ' "${n}"
    API_HOST=${n} api GET sys/seal-status --max-time 5 | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin); print("sealed" if d["sealed"] else "unsealed")
except Exception:
    print("does not answer")'
  done
  local hdr; hdr=$(admin_login)
  echo "  cluster:"
  api GET sys/storage/raft/configuration -H @"${hdr}" | python3 -c 'import json,sys
for s in json.load(sys.stdin)["data"]["config"]["servers"]:
    print("   ", s["node_id"], "leader" if s["leader"] else "follower", "voter" if s["voter"] else "non-voter")'
  echo "  audit logs:"
  api GET sys/audit -H @"${hdr}" | python3 -c 'import json,sys
d = json.load(sys.stdin).get("data", {})
for k, v in d.items():
    print("   ", k, v["type"], v["options"].get("file_path") or v["options"].get("address", ""))'
  echo "  XPAM logins:"
  api LIST auth/cert/certs -H @"${hdr}" | python3 -c 'import json,sys; print("   ", " ".join(json.load(sys.stdin)["data"]["keys"]))'
  api_code POST auth/token/revoke-self -H @"${hdr}" >/dev/null
}

cmd_add_xpam() {
  local ip=${1:-}
  valid_ip "${ip}" || die "usage: xpam-vault.sh add-xpam <ip>"
  load_env; scratch
  [[ ",${XPAM_IPS}," == *",${ip},"* ]] || die "${ip} is not one of the XPAM servers set at init (${XPAM_IPS}): administrators cannot add new addresses — that needs an emergency root token (vault operator generate-root, ${KEY_THRESHOLD} share holders)"
  local hdr; hdr=$(admin_login)
  xpam_role "${hdr}" "${ip}"
  ca_key_open
  bundle_passphrase
  xpam_bundle "${ip}"
  api_code POST auth/token/revoke-self -H @"${hdr}" >/dev/null
  echo "  bundle: ${BASE}/out/xpam-vault-${ip}.enc  →  xpamctl vault connect xpam-vault-${ip}.enc"
}

cmd_snapshot() {
  local file=${1:-}
  [[ -n "${file}" ]] || die "usage: xpam-vault.sh snapshot <file>"
  load_env; scratch
  local hdr; hdr=$(admin_login)
  local code
  code=$(api GET sys/storage/raft/snapshot -H @"${hdr}" -o "${file}" -w '%{http_code}')
  api_code POST auth/token/revoke-self -H @"${hdr}" >/dev/null
  [[ "${code}" == 200 ]] || { rm -f "${file}"; die "snapshot failed (${code})"; }
  chmod 600 "${file}"
  echo "  ${file} ($(du -h "${file}" | cut -f1)) — encrypted by Vault; restoring it needs the unseal key shares"
}

[[ $(id -u) -eq 0 ]] || die "run as root"
case "${1:-}" in
  init) shift; cmd_init "$@" ;;
  join) shift; cmd_join "$@" ;;
  unseal) cmd_unseal ;;
  status) cmd_status ;;
  add-xpam) shift; cmd_add_xpam "$@" ;;
  snapshot) shift; cmd_snapshot "$@" ;;
  auto-unseal) cmd_auto_unseal ;;
  *) sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
