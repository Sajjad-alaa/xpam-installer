#!/usr/bin/env bash
#
# XPAM and HashiCorp Vault (the XPAM Vault kit, vault/xpam-vault.sh, on separate servers).
#
#   xpamctl vault connect <xpam-vault-IP.enc> [-y]   move XPAM's secrets into Vault (this server)
#   xpamctl vault status                             connection, login, where each secret is
#   xpamctl vault fetch [--wait]                     read the secrets from Vault into memory (boot service)
#   xpamctl vault disconnect [-y]                    bring everything back to this server (config.txt, database)
#
# After `connect`:
#   - SECRET_KEY, the database / Redis / component passwords and tokens are in Vault only: config.txt, Docker's
#     container settings and backups of this server hold none of them. At boot, xpam-secrets.service logs in to
#     Vault with this server's client certificate and writes them to memory (/run/xpam/secrets, a tmpfs); each
#     container reads only the ones it uses from there when it starts.
#   - Account passwords and keys are stored in Vault (encrypted with SECRET_KEY first: Vault's administrators
#     cannot read them either), the database keeps none.
#   - The vault settings are locked in the console (VAULT_LOCKED): only this command changes them.
#   - A recovery copy of the secrets (escrow.enc) is encrypted with the recovery passphrase shown once: with it
#     XPAM can be brought back even if Vault is lost.
set -o pipefail
export XPAM_VAULT_NO_GUARD=1

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
. "${BASE_DIR}/utils.sh"

VDIR="${CONFIG_DIR}/vault"           # this server's Vault client files (root only)
RUN="${XPAM_SECRETS_RUN_DIR}"        # secrets in memory
VCLIENT_IN_CONTAINER="/opt/xpam-vault-client"

# which secrets each container receives (NAME or NAME=SOURCE) — the same allow-list as the compose files
declare -A SERVICE_SECRETS=(
  [core]="SECRET_KEY BOOTSTRAP_TOKEN DB_PASSWORD REDIS_PASSWORD BROWSER_KEY CHAT_AI_API_KEY CHAT_AI_DELEGATION_SECRET VAULT_OPENBAO_TOKEN SSH_CA_OPENBAO_TOKEN"
  [koko]="BOOTSTRAP_TOKEN BROWSER_KEY REDIS_PASSWORD=REDIS_KOKO_PASSWORD"
  [chen]="BOOTSTRAP_TOKEN"
  [kael]="BOOTSTRAP_TOKEN CHAT_AI_API_KEY PLATFORM_DELEGATION_KEY=CHAT_AI_DELEGATION_SECRET"
  [browser]="BROWSER_KEY"
  [redis]="REDIS_PASSWORD REDIS_KOKO_PASSWORD"
  [postgresql]="DB_PASSWORD POSTGRES_PASSWORD=DB_PASSWORD HA_REPL_PASSWORD HA_PATRONI_PASSWORD HA_REWIND_PASSWORD HA_ETCD_PASSWORD"
)
declare -A SERVICE_UID=([browser]=1000)

venv() { # key — from this server's vault.env
  local line
  while IFS= read -r line; do [[ "${line}" == "$1="* ]] && { echo "${line#*=}"; return; }; done < "${VDIR}/vault.env"
}

# ---------------------------------------------------------------- Vault API (curl, certificate login)

SCRATCH=""
scratch() {
  if [[ -z "${SCRATCH}" ]]; then
    SCRATCH=$(mktemp -d /dev/shm/xpam-vault.XXXXXX); chmod 700 "${SCRATCH}"
    trap 'rm -rf "${SCRATCH}"' EXIT
  fi
}

vcurl() { # url-path [curl args] — tries each Vault server in turn
  local path=$1; shift
  local addr code
  for addr in $(venv VAULT_ADDRS | tr ',' ' '); do
    code=$(curl -s --max-time 15 --cacert "${VDIR}/ca.crt" --cert "${VDIR}/client.crt" --key "${VDIR}/client.key" \
      -o "${SCRATCH}/out" -w '%{http_code}' "$@" "${addr}/v1/${path}") || continue
    [[ "${code}" == 000 ]] && continue
    echo "${code}"; return 0
  done
  echo 000
}

vault_login() { # → SCRATCH/token.hdr
  scratch
  local code
  code=$(vcurl auth/cert/login -X POST -d "{\"name\":\"$(venv VAULT_ROLE)\"}")
  [[ "${code}" == 200 ]] || { echo "login refused (${code}): $(head -c 300 "${SCRATCH}/out" 2>/dev/null)" >&2; return 1; }
  printf 'X-Vault-Token: %s\n' "$(python3 -c 'import json,sys; print(json.load(sys.stdin)["auth"]["client_token"])' < "${SCRATCH}/out")" \
    > "${SCRATCH}/token.hdr"
}

vault_logout() { [[ -s "${SCRATCH}/token.hdr" ]] && vcurl auth/token/revoke-self -X POST -H @"${SCRATCH}/token.hdr" >/dev/null; }

vault_read_startup() { # → SCRATCH/startup.json ({} when empty)
  local code
  code=$(vcurl "$(venv VAULT_STARTUP_PATH)" -H @"${SCRATCH}/token.hdr")
  case "${code}" in
    200) python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["data"]["data"] or {}))' < "${SCRATCH}/out" > "${SCRATCH}/startup.json" ;;
    404) echo '{}' > "${SCRATCH}/startup.json" ;;
    *) echo "reading the startup secrets failed (${code}): $(head -c 300 "${SCRATCH}/out")" >&2; return 1 ;;
  esac
}

vault_write_startup() { # file.json — the whole set (Vault keeps the previous versions)
  local code
  code=$(python3 -c 'import json,sys; print(json.dumps({"data": json.load(open(sys.argv[1]))}))' "$1" \
    | vcurl "$(venv VAULT_STARTUP_PATH)" -X POST -H @"${SCRATCH}/token.hdr" --data @-)
  [[ "${code}" == 200 ]] || { echo "writing the startup secrets failed (${code}): $(head -c 300 "${SCRATCH}/out")" >&2; return 1; }
}

# ---------------------------------------------------------------- secrets in memory

write_run_files() { # SCRATCH/startup.json → /run/xpam/secrets/{all.env,<service>/env}
  mkdir -p "${RUN}"; chmod 711 "$(dirname "${RUN}")" "${RUN}"
  local svc
  python3 - "${SCRATCH}/startup.json" "${RUN}" <<'EOF'
import json, os, sys
data = json.load(open(sys.argv[1]))
run = sys.argv[2]
tmp = os.path.join(run, '.all.env.tmp')
with open(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), 'w') as f:
    for k, v in sorted(data.items()):
        if '\n' not in str(v):
            f.write(f'{k}={v}\n')
os.replace(tmp, os.path.join(run, 'all.env'))
EOF
  for svc in "${!SERVICE_SECRETS[@]}"; do
    mkdir -p "${RUN}/${svc}"
    python3 - "${SCRATCH}/startup.json" "${RUN}/${svc}" "${SERVICE_SECRETS[${svc}]}" "${SERVICE_UID[${svc}]:-0}" <<'EOF'
import json, os, sys
data = json.load(open(sys.argv[1]))
d, spec, uid = sys.argv[2], sys.argv[3].split(), int(sys.argv[4])
tmp = os.path.join(d, '.env.tmp')
with open(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o400), 'w') as f:
    for item in spec:
        name, _, source = item.partition('=')
        value = str(data.get(source or name, ''))
        if value:
            f.write("%s='%s'\n" % (name, value.replace("'", "'\\''")))
os.chown(tmp, uid, uid)
os.chown(d, uid, uid)
os.chmod(d, 0o700)
os.replace(tmp, os.path.join(d, 'env'))
EOF
  done
}

install_boot_service() {
  cat > /etc/tmpfiles.d/xpam-secrets.conf <<EOF
# XPAM: secrets read from Vault at boot live here (memory only); one folder per container
d ${RUN%/secrets} 0711 root root -
d ${RUN} 0711 root root -
EOF
  local svc
  for svc in "${!SERVICE_SECRETS[@]}"; do
    echo "d ${RUN}/${svc} 0700 ${SERVICE_UID[${svc}]:-0} ${SERVICE_UID[${svc}]:-0} -" >> /etc/tmpfiles.d/xpam-secrets.conf
  done
  systemd-tmpfiles --create /etc/tmpfiles.d/xpam-secrets.conf 2>/dev/null || true
  cat > /etc/systemd/system/xpam-secrets.service <<EOF
[Unit]
Description=XPAM secrets from Vault (into memory, for the containers)
After=network-online.target systemd-tmpfiles-setup.service
Wants=network-online.target
Before=docker.service

[Service]
Type=simple
ExecStart=/bin/bash ${BASE_DIR}/vault.sh fetch --wait
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable xpam-secrets.service >/dev/null 2>&1
}

# ---------------------------------------------------------------- helpers

blank_config() { # key — remove a secret's value from config.txt (directly: set_config would write to Vault)
  local key=$1 tmp line
  tmp=$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ "${line}" =~ ^[[:space:]]*${key}= ]]; then printf '%s=\n' "${key}"; else printf '%s\n' "${line}"; fi
  done < "${CONFIG_FILE}" > "${tmp}"
  chmod 600 "${tmp}"; mv -f "${tmp}" "${CONFIG_FILE}"
}

config_value() { # key — from config.txt only (no Vault fallback)
  local line value=''
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ "${line}" =~ ^[[:space:]]*$1= ]] && value=${line#*=}
  done < "${CONFIG_FILE}"
  echo "${value}"
}

core_exec() { docker exec -i xpam_core bash -c "cd /opt/jumpserver/apps && python manage.py shell" 2>/dev/null; }

secrets_left_on_disk() { # files on this server that still hold a SECRET_KEY value
  grep -rlE '^[[:space:]]*SECRET_KEY=.+' "${CONFIG_DIR}" "$(get_config VOLUME_DIR)/core/data/backup" 2>/dev/null \
    | grep -v "^${CONFIG_FILE}$" || true
  ls "${CONFIG_DIR}"/ha/*.enc 2>/dev/null || true
}

# ---------------------------------------------------------------- commands

cmd_fetch() {
  local wait=$1 i
  scratch
  [[ -f "${VDIR}/vault.env" ]] || { echo "not connected to Vault" >&2; return 1; }
  for i in $(seq 1 100000); do
    if vault_login && vault_read_startup; then
      vault_logout
      write_run_files
      rm -f "${SCRATCH}/startup.json"
      return 0
    fi
    [[ "${wait}" == "--wait" ]] || return 1
    sleep 10
  done
}

cmd_put() { # key (value in XV_VALUE) — one secret into Vault, then into memory
  local key=$1
  is_vault_secret_key "${key}" || { echo "not a Vault-managed secret: ${key}" >&2; return 1; }
  [[ -n "${XV_VALUE:-}" ]] || return 0
  scratch
  vault_login && vault_read_startup || return 1
  python3 - "${SCRATCH}/startup.json" "${key}" <<'EOF' || { vault_logout; return 0; }
import json, os, sys
path, key = sys.argv[1], sys.argv[2]
data = json.load(open(path))
if data.get(key) == os.environ['XV_VALUE']:
    sys.exit(1)            # unchanged: nothing to write
data[key] = os.environ['XV_VALUE']
json.dump(data, open(path, 'w'))
EOF
  vault_write_startup "${SCRATCH}/startup.json" || { vault_logout; return 1; }
  vault_logout
  write_run_files
}

cmd_connect() {
  local bundle=$1 yes=$2
  [[ -f "${bundle}" ]] || { echo "usage: xpamctl vault connect <xpam-vault-IP.enc> [-y]"; return 2; }
  if secrets_from_vault; then log_error "This server is already connected to Vault (xpamctl vault status)"; return 1; fi
  docker ps --format '{{.Names}}' | grep -qx xpam_core || { log_error "XPAM must be running (xpamctl start)"; return 1; }
  local unsupported
  unsupported=$(docker ps --format '{{.Names}}' | grep -E '^xpam_(video_worker|nec|magnus|razor|xrdp)$' | tr '\n' ' ')
  if [[ -n "${unsupported}" ]]; then
    log_error "These components cannot take their secrets from Vault yet: ${unsupported}(disable them first)"; return 1
  fi
  scratch

  export XV_BUNDLE_PW="$(passphrase_from XPAM_VAULT_BUNDLE_PASSPHRASE "Bundle passphrase")"
  local d; d=$(mktemp -d "${SCRATCH}/b.XXXX")
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass env:XV_BUNDLE_PW -in "${bundle}" 2>/dev/null | tar xzf - -C "${d}" 2>/dev/null
  [[ -f "${d}/vault.env" && -f "${d}/client.key" ]] || { log_error "Wrong bundle passphrase (or not an XPAM bundle of the Vault kit)"; return 1; }
  mkdir -p "${VDIR}"; chmod 700 "${VDIR}"
  install -m 644 "${d}/ca.crt" "${VDIR}/ca.crt"
  install -m 644 "${d}/client.crt" "${VDIR}/client.crt"
  install -m 600 "${d}/client.key" "${VDIR}/client.key"
  install -m 600 "${d}/vault.env" "${VDIR}/vault.env"
  rm -rf "${d}"

  echo
  echo "  Vault         $(venv VAULT_ADDRS)"
  echo "  this server   login $(venv VAULT_ROLE)"
  echo "  XPAM restarts once (a few minutes offline); its secrets then live in Vault only."
  if [[ "${yes}" != "-y" ]]; then
    read_from_input confirm "$(gettext 'Continue?') (y/n)" "y/n" "n"
    [[ "${confirm}" == "y" ]] || return 1
  fi

  echo_yellow "1. Vault login and rights"
  vault_login || { log_error "This server cannot log in to Vault (address allowed? certificate?)"; return 1; }
  vault_read_startup || return 1
  echo_check "logged in; startup secrets in Vault: $(python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' < "${SCRATCH}/startup.json")"

  echo_yellow "2. Startup secrets into Vault"
  python3 - "${SCRATCH}/startup.json" "${CONFIG_FILE}" "${XPAM_VAULT_SECRET_KEYS}" <<'EOF' || return 1
import json, sys
path, config, keys = sys.argv[1], sys.argv[2], sys.argv[3].split()
vault = json.load(open(path))
local = {}
for line in open(config):
    line = line.rstrip('\n')
    if '=' in line and not line.lstrip().startswith('#'):
        k, v = line.split('=', 1)
        k = k.strip()
        if k in keys and v:
            local[k] = v
conflicts = [k for k in local if k in vault and vault[k] != local[k]]
if conflicts:
    print('  Vault already holds different values for: ' + ', '.join(conflicts), file=sys.stderr)
    print('  (another XPAM installation with the same name in Vault?) — nothing changed', file=sys.stderr)
    sys.exit(1)
merged = dict(local, **vault)
missing = [k for k in ('SECRET_KEY', 'BOOTSTRAP_TOKEN', 'DB_PASSWORD') if not merged.get(k)]
if missing:
    print('  missing secrets: ' + ', '.join(missing), file=sys.stderr); sys.exit(1)
json.dump(merged, open(path, 'w'))
print('  ' + ', '.join(sorted(merged)))
EOF
  cp "${SCRATCH}/startup.json" "${SCRATCH}/written.json"
  vault_write_startup "${SCRATCH}/written.json" || return 1
  vault_read_startup || return 1
  python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])) == json.load(open(sys.argv[2])) else 1)' \
    "${SCRATCH}/written.json" "${SCRATCH}/startup.json" || { log_error "Vault returned different values: stopped"; return 1; }
  echo_check "written and read back"

  echo_yellow "3. Recovery copy (if Vault were ever lost)"
  local rpw
  if [[ -n "${XPAM_VAULT_RECOVERY_PASSPHRASE:-}" ]]; then rpw="${XPAM_VAULT_RECOVERY_PASSPHRASE}"; else
    rpw="$(random_str 32)"
  fi
  XV_R="${rpw}" openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -pass env:XV_R -in "${SCRATCH}/startup.json" \
    -out "${VDIR}/escrow.enc" && chmod 600 "${VDIR}/escrow.enc"
  echo_check "${VDIR}/escrow.enc (recovery passphrase below)"

  echo_yellow "4. Secrets into memory at every boot (xpam-secrets.service)"
  write_run_files
  install_boot_service
  echo_check "${RUN}"

  echo_yellow "5. Configuration: account storage in Vault, settings locked, secrets removed from config.txt"
  local addrs; addrs=$(venv VAULT_ADDRS)
  set_config VAULT_ENABLED true
  set_config VAULT_BACKEND hcp
  set_config VAULT_HCP_HOST "${addrs}"
  set_config VAULT_HCP_AUTH cert
  set_config VAULT_HCP_CERT_ROLE "$(venv VAULT_ROLE)"
  set_config VAULT_HCP_MOUNT_POINT "$(venv VAULT_ACCOUNT_MOUNT)"
  set_config VAULT_HCP_CA_FILE "${VCLIENT_IN_CONTAINER}/ca.crt"
  set_config VAULT_HCP_CLIENT_CERT_FILE "${VCLIENT_IN_CONTAINER}/client.crt"
  set_config VAULT_HCP_CLIENT_KEY_FILE "${VCLIENT_IN_CONTAINER}/client.key"
  set_config VAULT_LOCKED true
  local key
  for key in ${XPAM_VAULT_SECRET_KEYS}; do blank_config "${key}"; done
  set_config XPAM_SECRETS_FROM_VAULT 1
  gen_safe_config >/dev/null 2>&1 || true
  echo_check "config.txt holds no secrets"

  echo_yellow "6. Restarting XPAM (containers recreated: none keeps a secret in its settings)"
  (cd "${PROJECT_DIR}" && bash ./xpamctl.sh down >/dev/null 2>&1; bash ./xpamctl.sh start >/dev/null 2>&1)
  local i
  for i in $(seq 1 90); do
    docker ps --format '{{.Names}} {{.Status}}' | grep -q '^xpam_core .*(healthy)' && break; sleep 5
  done
  docker ps --format '{{.Names}} {{.Status}}' | grep -q '^xpam_core .*(healthy)' \
    || { log_error "XPAM did not come back (xpamctl status); secrets are safe in Vault and in the recovery copy"; return 1; }
  echo_check "XPAM is running with its secrets from Vault"

  echo_yellow "7. Account passwords and keys into Vault"
  local left
  left=$(core_exec <<'EOF' | tail -1
from accounts.tasks.vault import sync_secret_to_vault
sync_secret_to_vault()
from accounts.models import Account, AccountTemplate, PersonalAssetCredential
from accounts.models.mixins.vault import VAULT_SAVED_SECRET_MARK
n = 0
for model in (Account, AccountTemplate, PersonalAssetCredential):
    n += sum(1 for o in model.objects.only('id', '_secret').iterator() if o._secret and o._secret != VAULT_SAVED_SECRET_MARK)
print(n)
EOF
)
  if [[ "${left}" == 0 ]]; then echo_check "the database keeps no account secret"; else
    echo_warn "account secrets still in the database: ${left:-unknown} (xpamctl vault status; the console: System settings → Vault → Sync)"
  fi
  vault_logout

  echo
  echo_green "XPAM's secrets are in Vault."
  echo_yellow "Recovery passphrase (opens ${VDIR}/escrow.enc if Vault is lost — keep it offline, apart from the server):"
  [[ -n "${XPAM_VAULT_RECOVERY_PASSPHRASE:-}" ]] && echo "  (the one you set in XPAM_VAULT_RECOVERY_PASSPHRASE)" || echo "  ${rpw}"
  local old; old=$(secrets_left_on_disk)
  if [[ -n "${old}" ]]; then
    echo_yellow "Older copies still hold secrets on this server — move them offline or delete them (shred -u):"
    echo "${old}" | sed 's/^/  /'
  fi
  echo "  Delete the bundle: shred -u ${bundle}"
}

cmd_status() {
  scratch
  if ! secrets_from_vault; then echo "  not connected to Vault (secrets in ${CONFIG_FILE})"; return 0; fi
  echo "  Vault           $(venv VAULT_ADDRS)"
  echo "  login           $(venv VAULT_ROLE)"
  if vault_login && vault_read_startup; then
    echo "  login           OK"
    echo "  in Vault        $(python3 -c 'import json,sys; print(" ".join(sorted(json.load(sys.stdin))))' < "${SCRATCH}/startup.json")"
    vault_logout
  else
    echo "  login           FAILED"
  fi
  echo "  in memory       $([[ -s "${RUN}/all.env" ]] && echo "yes (${RUN})" || echo "NO — systemctl status xpam-secrets")"
  local key left=""
  for key in ${XPAM_VAULT_SECRET_KEYS}; do [[ -n "$(config_value "${key}")" ]] && left+=" ${key}"; done
  echo "  in config.txt   ${left:-none}"
  echo "  boot service    $(systemctl is-enabled xpam-secrets.service 2>/dev/null)"
  local n
  n=$(core_exec <<'EOF' | tail -1
from accounts.models import Account
from accounts.models.mixins.vault import VAULT_SAVED_SECRET_MARK
print(sum(1 for o in Account.objects.only('id', '_secret').iterator() if o._secret and o._secret != VAULT_SAVED_SECRET_MARK))
EOF
)
  echo "  account secrets in the database: ${n:-unknown}"
}

cmd_disconnect() {
  local yes=$1
  secrets_from_vault || { echo "  not connected"; return 0; }
  echo "  This brings the secrets back into config.txt and the account passwords back into the database,"
  echo "  then stops using Vault (XPAM restarts)."
  if [[ "${yes}" != "-y" ]]; then
    read_from_input confirm "$(gettext 'Continue?') (y/n)" "y/n" "n"
    [[ "${confirm}" == "y" ]] || return 1
  fi
  scratch
  if ! cmd_fetch; then
    log_error "Vault cannot be read. To recover from the recovery copy: openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in ${VDIR}/escrow.enc"
    return 1
  fi
  echo_yellow "1. Account secrets back into the database"
  core_exec <<'EOF' >/dev/null
from accounts.tasks.vault import restore_secret_from_vault
restore_secret_from_vault()
EOF
  echo_yellow "2. Secrets back into config.txt"
  local line key value
  set_config XPAM_SECRETS_FROM_VAULT 0
  while IFS= read -r line; do
    key=${line%%=*}; value=${line#*=}
    set_config "${key}" "${value}"
  done < "${RUN}/all.env"
  set_config VAULT_ENABLED false
  set_config VAULT_LOCKED false
  set_config VAULT_HCP_AUTH token
  systemctl disable --now xpam-secrets.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/xpam-secrets.service /etc/tmpfiles.d/xpam-secrets.conf
  systemctl daemon-reload
  rm -rf "${RUN}"
  echo_yellow "3. Restarting XPAM"
  (cd "${PROJECT_DIR}" && bash ./xpamctl.sh down >/dev/null 2>&1; bash ./xpamctl.sh start >/dev/null 2>&1)
  echo_green "Disconnected: secrets are in ${CONFIG_FILE} again (Vault still holds its copies: remove them there)."
}

passphrase_from() { # VAR "what": from the environment (automation), else typed (not shown)
  local var=$1 what=$2 value
  value="${!var:-}"
  if [[ -z "${value}" ]]; then
    read -r -s -p "  ${what}: " value </dev/tty; echo >&2
  fi
  printf '%s' "${value}"
}

[[ $(id -u) -eq 0 ]] || { echo "run as root"; exit 1; }
case "${1:-}" in
  connect) cmd_connect "${2:-}" "${3:-}" ;;
  status) cmd_status ;;
  fetch) cmd_fetch "${2:-}" ;;
  put) cmd_put "${2:-}" ;;
  disconnect) cmd_disconnect "${2:-}" ;;
  *) sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
