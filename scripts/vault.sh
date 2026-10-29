#!/usr/bin/env bash
#
# XPAM and HashiCorp Vault (the XPAM Vault kit, vault/xpam-vault.sh, on separate servers).
#
#   xpamctl vault connect <xpam-vault-IP.enc> [-y] [--keep-db-copy]   move XPAM's secrets into Vault (this server);
#                                                    when already connected: move them to that Vault (e.g. local ->
#                                                    servers)
#   xpamctl vault local [--keep-db-copy]             a hardened Vault on this server (default at install)
#   xpamctl vault keep-db-copy on|off                account passwords in Vault and a copy in the database (read
#                                                    when Vault does not answer), or in Vault only (the default)
#   xpamctl vault add-connection <name> <type> <settings.json | --bundle file>   a further vault (several vaults:
#                                                    storage rules per organization / asset group, mirrors)
#   xpamctl vault list-connections | remove-connection <name>
#   xpamctl vault rotation daily|weekly|monthly|off  how often the data key rotates (no downtime)
#   xpamctl vault data-key local|legacy              without Vault: a versioned keyring (rotated) or SECRET_KEY
#   xpamctl vault status                             connection, login, where each secret is
#   xpamctl vault verify                             prove it: TLS 1.3, certificates, least privilege, no secret left
#   xpamctl vault fetch [--wait]                     read the secrets from Vault into memory (boot service)
#   xpamctl vault disconnect [-y]                    bring everything back to this server (config.txt, database)
#
# After `connect`:
#   - SECRET_KEY, the database / Redis / component passwords and tokens are in Vault only: config.txt, Docker's
#     container settings and backups of this server hold none of them. At boot, xpam-secrets.service logs in to
#     Vault with this server's client certificate and writes them to memory (/run/xpam/secrets, a tmpfs); each
#     container reads only the ones it uses from there when it starts.
#   - Account passwords and keys are stored in Vault (encrypted with SECRET_KEY first: Vault's administrators
#     cannot read them either), the database keeps none — unless --keep-db-copy (VAULT_KEEP_DB_COPY): then the
#     database keeps a copy too, encrypted with the local data key (not Vault Transit, so the copy can be read
#     without Vault), and XPAM reads it when Vault does not answer. XPAM's own secrets stay in Vault either way.
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
  [core]="SECRET_KEY SECRET_KEY_PREVIOUS BOOTSTRAP_TOKEN DB_PASSWORD REDIS_PASSWORD BROWSER_KEY CHAT_AI_API_KEY CHAT_AI_DELEGATION_SECRET VAULT_OPENBAO_TOKEN SSH_CA_OPENBAO_TOKEN"
  [koko]="BOOTSTRAP_TOKEN BROWSER_KEY REDIS_PASSWORD=REDIS_KOKO_PASSWORD"
  [chen]="BOOTSTRAP_TOKEN"
  [kael]="BOOTSTRAP_TOKEN CHAT_AI_API_KEY PLATFORM_DELEGATION_KEY=CHAT_AI_DELEGATION_SECRET"
  [facelive]="BOOTSTRAP_TOKEN"
  [browser]="BROWSER_KEY"
  [redis]="REDIS_PASSWORD REDIS_KOKO_PASSWORD"
  [postgresql]="DB_PASSWORD POSTGRES_PASSWORD=DB_PASSWORD HA_REPL_PASSWORD HA_PATRONI_PASSWORD HA_REWIND_PASSWORD HA_ETCD_PASSWORD"
)
declare -A SERVICE_UID=([browser]=1000 [facelive]=10001)

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

vcurl() { # url-path [curl args] — tries each Vault server in turn (not --data @-: a body is read once)
  local path=$1; shift
  local addr code sealed=""
  for addr in $(venv VAULT_ADDRS | tr ',' ' '); do
    code=$(curl -s --tlsv1.3 --max-time 15 --cacert "${VDIR}/ca.crt" --cert "${VDIR}/client.crt" --key "${VDIR}/client.key" \
      -o "${SCRATCH}/out" -w '%{http_code}' "$@" "${addr}/v1/${path}") || continue
    [[ "${code}" == 000 ]] && continue
    # (a sealed server answers 503: another one may be unsealed)
    [[ "${code}" == 503 ]] && { sealed=503; continue; }
    echo "${code}"; return 0
  done
  echo "${sealed:-000}"
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
  python3 -c 'import json,sys; print(json.dumps({"data": json.load(open(sys.argv[1]))}))' "$1" > "${SCRATCH}/payload.json" || return 1
  code=$(vcurl "$(venv VAULT_STARTUP_PATH)" -X POST -H @"${SCRATCH}/token.hdr" --data @"${SCRATCH}/payload.json")
  rm -f "${SCRATCH}/payload.json"
  [[ "${code}" == 200 ]] || { echo "writing the startup secrets failed (${code}): $(head -c 300 "${SCRATCH}/out")" >&2; return 1; }
}

# ---------------------------------------------------------------- secrets in memory

write_run_files() { # SCRATCH/startup.json → /run/xpam/secrets/{all.env,<service>/env}
  mkdir -p "${RUN}" && chmod 711 "$(dirname "${RUN}")" "${RUN}" || return 1
  local svc
  python3 - "${SCRATCH}/startup.json" "${RUN}" <<'EOF' || return 1
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
    mkdir -p "${RUN}/${svc}" || return 1
    python3 - "${SCRATCH}/startup.json" "${RUN}/${svc}" "${SERVICE_SECRETS[${svc}]}" "${SERVICE_UID[${svc}]:-0}" <<'EOF' || return 1
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
  # (config.txt copies: next to config.txt — .bak-*, .before-ha-* —, in the upgrade / key rotation backups
  # (db_backup: config-*.conf, config-before-key-rotation-*.txt) and in the "xpamctl config" backups)
  local volume_dir
  volume_dir=$(get_config VOLUME_DIR)
  grep -rIlE '^[[:space:]]*SECRET_KEY=.+' "${CONFIG_DIR}" "${volume_dir}/db_backup" "${volume_dir}/config_backup" \
    "${volume_dir}/core/data/backup" 2>/dev/null \
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
      # (an empty answer, e.g. a Vault without XPAM's secrets, would leave every container without its secrets)
      if python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("SECRET_KEY") else 1)' "${SCRATCH}/startup.json" \
          && write_run_files; then
        rm -f "${SCRATCH}/startup.json"
        return 0
      fi
      echo "Vault holds no XPAM secrets for this installation (or they could not be written to ${RUN})" >&2
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
  local rc=0
  python3 - "${SCRATCH}/startup.json" "${key}" <<'EOF' || rc=$?
import json, os, sys
path, key = sys.argv[1], sys.argv[2]
data = json.load(open(path))
if data.get(key) == os.environ['XV_VALUE']:
    sys.exit(3)            # unchanged: nothing to write
data[key] = os.environ['XV_VALUE']
json.dump(data, open(path, 'w'))
EOF
  # (3: unchanged; any other failure must not look like "nothing to do": the new value would be lost)
  [[ "${rc}" == 3 ]] && { vault_logout; return 0; }
  [[ "${rc}" == 0 ]] || { vault_logout; return 1; }
  vault_write_startup "${SCRATCH}/startup.json" || { vault_logout; return 1; }
  vault_logout
  write_run_files
}

connect_undo() { # a move that stopped before the switch: the current Vault stays in use, with its secrets
  if [[ "${CONNECT_MOVED_DIR}" == 1 && -d "${VDIR}.previous" ]]; then
    rm -rf "${VDIR}"; mv "${VDIR}.previous" "${VDIR}"
  fi
  if [[ "${CONNECT_TAKEN_OUT}" == 1 ]]; then
    echo_warn "Nothing was moved: the account secrets go back into the current Vault"
    core_exec <<'PY' >/dev/null || echo_warn "They are still in the database: the console System settings → Vault → Sync moves them"
from accounts.tasks.vault import sync_secret_to_vault
r = sync_secret_to_vault()
if r.get('status') != 'succeeded':
    raise SystemExit(1)
PY
    reencrypt_with_current_key >/dev/null || true
  fi
}

cmd_connect() {
  local rc=0
  CONNECT_MOVED_DIR=0; CONNECT_TAKEN_OUT=0; CONNECT_COMMITTED=0
  cmd_connect_run "$@" || rc=$?
  [[ "${rc}" == 0 || "${CONNECT_COMMITTED}" == 1 ]] || connect_undo
  return "${rc}"
}

cmd_connect_run() {
  local bundle=$1 yes=$2
  [[ -f "${bundle}" ]] || { echo "usage: xpamctl vault connect <xpam-vault-IP.enc> [-y]"; return 2; }
  # already connected: a move (e.g. from the local Vault to the Vault servers) — the secrets come from memory
  local moving=0 source_file="${CONFIG_FILE}"
  if secrets_from_vault; then
    moving=1
    [[ -s "${RUN}/all.env" ]] || { log_error "The current Vault cannot be read (xpamctl vault status): nothing to move"; return 1; }
  fi
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
  if [[ "${moving}" == 1 ]]; then
    echo_yellow "0. Moving from $(venv VAULT_ADDRS): account secrets back into the database first"
    CONNECT_TAKEN_OUT=1
    to_legacy_data_key >/dev/null || { log_error "Reading the secrets from the current Vault failed: nothing changed"; return 1; }
    cp "${RUN}/all.env" "${SCRATCH}/current.env"; source_file="${SCRATCH}/current.env"
    rm -rf "${VDIR}.previous"; mv "${VDIR}" "${VDIR}.previous"
    CONNECT_MOVED_DIR=1
  fi
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
  python3 - "${SCRATCH}/startup.json" "${source_file}" "${XPAM_VAULT_SECRET_KEYS}" <<'EOF' || return 1
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
  (umask 077 && XV_R="${rpw}" openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -pass env:XV_R -in "${SCRATCH}/startup.json" \
    -out "${VDIR}/escrow.enc") && [[ -s "${VDIR}/escrow.enc" ]] || { log_error "The recovery copy could not be written: stopped"; return 1; }
  echo_check "${VDIR}/escrow.enc (recovery passphrase below)"

  echo_yellow "4. Secrets into memory at every boot (xpam-secrets.service)"
  write_run_files
  install_boot_service
  echo_check "${RUN}"

  echo_yellow "5. Configuration: account storage in Vault, settings locked, secrets removed from config.txt"
  CONNECT_COMMITTED=1
  set_vault_config
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
  local left copies
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
  if [[ "$(get_config XPAM_DATA_KEY)" == transit ]]; then
    reencrypt_with_current_key >/dev/null && echo_check "every encrypted value now uses the data key in Vault (Transit)" \
      || echo_warn "re-encryption with the Vault data key will finish in the background (daily task)"
  elif keep_db_copy; then
    reencrypt_with_current_key >/dev/null || echo_warn "re-encryption with the local data key will finish in the background (daily task)"
  fi
  if keep_db_copy; then
    copies=$(update_copies)
    if [[ "${left}" == 0 ]]; then echo_check "account secrets are in Vault, with a copy in the database (${copies})"; else
      echo_warn "account secrets not in Vault yet: ${left:-unknown} (they stay in the database; the console: System settings → Vault → Sync)"
    fi
  elif [[ "${left}" == 0 ]]; then echo_check "the database keeps no account secret"; else
    echo_warn "account secrets still in the database: ${left:-unknown} (xpamctl vault status; the console: System settings → Vault → Sync)"
  fi
  vault_logout
  if [[ "${moving}" == 1 && -f /opt/xpam-vault/kit.env ]] && grep -q '^LOCAL=1' /opt/xpam-vault/kit.env; then
    echo_yellow "8. The local Vault is no longer used: stopped (its data is kept in /opt/xpam-vault until you delete it)"
    docker compose -f /opt/xpam-vault/compose.yml down >/dev/null 2>&1 || true
    systemctl disable --now xpam-vault-unseal.service xpam-vault-firewall.service >/dev/null 2>&1 || true
  fi
  rm -rf "${VDIR}.previous"

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

set_vault_config() { # XPAM's account storage in Vault with this server's login, locked; secrets out of config.txt
  set_config VAULT_ENABLED true
  set_config VAULT_BACKEND hcp
  set_config VAULT_HCP_HOST "$(venv VAULT_ADDRS)"
  set_config VAULT_HCP_AUTH cert
  set_config VAULT_HCP_CERT_ROLE "$(venv VAULT_ROLE)"
  set_config VAULT_HCP_MOUNT_POINT "$(venv VAULT_ACCOUNT_MOUNT)"
  set_config VAULT_HCP_CA_FILE "${VCLIENT_IN_CONTAINER}/ca.crt"
  set_config VAULT_HCP_CLIENT_CERT_FILE "${VCLIENT_IN_CONTAINER}/client.crt"
  set_config VAULT_HCP_CLIENT_KEY_FILE "${VCLIENT_IN_CONTAINER}/client.key"
  set_config VAULT_LOCKED true
  [[ "${KEEP_DB_COPY:-}" == 1 ]] && set_config VAULT_KEEP_DB_COPY true
  if [[ -n "$(venv VAULT_TRANSIT_MOUNT)" ]]; then
    set_config VAULT_TRANSIT_MOUNT "$(venv VAULT_TRANSIT_MOUNT)"
    set_config VAULT_TRANSIT_KEY data
  fi
  if keep_db_copy; then
    # the database copy must be readable without Vault: the local data key (a keyring in the database)
    set_config XPAM_DATA_KEY local
  elif [[ -n "$(venv VAULT_TRANSIT_MOUNT)" ]]; then
    # the data key in Vault Transit (bundles of the kit since 5.1.17): it never leaves Vault
    set_config XPAM_DATA_KEY transit
  fi
  local key
  for key in ${XPAM_VAULT_SECRET_KEYS}; do blank_config "${key}"; done
  set_config XPAM_SECRETS_FROM_VAULT 1
}

keep_db_copy() { [[ "$(get_config VAULT_KEEP_DB_COPY false)" == true ]]; }

update_copies() { # fills (VAULT_KEEP_DB_COPY) or removes the database copies of account secrets; prints a summary
  core_exec <<'PY' | tail -1
from django.conf import settings
from accounts.tasks.vault import update_secret_copies
kept, failed = update_secret_copies()
if not settings.VAULT_KEEP_DB_COPY:
    print('copies removed')
else:
    print(f'{kept} kept' + (f', {failed} could not be read from Vault' if failed else ''))
PY
}

wait_core() {
  local i
  for i in $(seq 1 90); do docker ps --format '{{.Names}} {{.Status}}' | grep -q '^xpam_core .*(healthy)' && return 0; sleep 5; done
  return 1
}

cmd_keep_db_copy() { # on|off — account passwords also in the database (read when Vault does not answer), or not
  local p=$1
  [[ "${p}" == on || "${p}" == off ]] || { echo "usage: xpamctl vault keep-db-copy on|off"; return 2; }
  secrets_from_vault || { log_error "Not connected to Vault: account secrets are in the database already"; return 1; }
  docker ps --format '{{.Names}}' | grep -qx xpam_core || { log_error "XPAM must be running (xpamctl start)"; return 1; }
  if [[ "${p}" == on ]]; then
    set_config VAULT_KEEP_DB_COPY true
    # (values under Vault Transit stay readable while they are re-encrypted with the local key)
    [[ "$(get_config XPAM_DATA_KEY)" == transit ]] && echo_yellow "  data key: from Vault Transit to the local keyring (the copy must be readable without Vault)"
    set_config XPAM_DATA_KEY local
  else
    set_config VAULT_KEEP_DB_COPY false
  fi
  echo_yellow "  restarting XPAM"
  (cd "${PROJECT_DIR}" && bash ./xpamctl.sh restart >/dev/null 2>&1)
  wait_core || { log_error "XPAM did not come back (xpamctl status)"; return 1; }
  if [[ "${p}" == on ]]; then
    reencrypt_with_current_key >/dev/null || echo_warn "re-encryption with the local data key will finish in the background (daily task)"
    echo_check "account secrets: in Vault, with a copy in the database ($(update_copies))"
  else
    echo_check "account secrets: in Vault only ($(update_copies))"
    if [[ -n "$(get_config VAULT_TRANSIT_MOUNT)" && "$(get_config XPAM_DATA_KEY)" != transit ]]; then
      echo_yellow "  data key: back to Vault Transit"
      set_config XPAM_DATA_KEY transit
      (cd "${PROJECT_DIR}" && bash ./xpamctl.sh restart >/dev/null 2>&1)
      wait_core || { log_error "XPAM did not come back (xpamctl status)"; return 1; }
      reencrypt_with_current_key >/dev/null && echo_check "every encrypted value uses the data key in Vault (Transit)" \
        || echo_warn "re-encryption with the Vault data key will finish in the background (daily task)"
    fi
  fi
}

to_legacy_data_key() { # every value back under SECRET_KEY (before leaving or changing Vault), account secrets included
  core_exec <<'PY'
from django.conf import settings
settings.XPAM_DATA_KEY = 'legacy'
import sys
from accounts.tasks.vault import restore_secret_from_vault
# (a secret that stayed in Vault, or a value that could not be re-encrypted, must stop the caller: it would
# switch to a setup that cannot read it)
if restore_secret_from_vault().get('status') != 'succeeded':
    sys.exit(1)
from settings.tasks.datakey import _reencrypt_database
done = _reencrypt_database(None)
print('re-encrypted', done)
if getattr(_reencrypt_database, 'failed', 0):
    sys.exit(1)
PY
}

reencrypt_with_current_key() { # after XPAM restarted with its data key: every value to it, now
  core_exec <<'PY'
import sys
from settings.tasks.datakey import rotate_data_keys
result = rotate_data_keys()
print(result)
if result.get('failed'):
    sys.exit(1)
PY
}

cmd_attach() { # dir (ca.crt, client.crt, client.key, vault.env) — 'ha join': the secrets are already in Vault
  local d=$1
  [[ -f "${d}/vault.env" && -f "${d}/client.key" ]] || { echo "no Vault login in ${d}" >&2; return 1; }
  scratch
  mkdir -p "${VDIR}"; chmod 700 "${VDIR}"
  install -m 644 "${d}/ca.crt" "${VDIR}/ca.crt"
  install -m 644 "${d}/client.crt" "${VDIR}/client.crt"
  install -m 600 "${d}/client.key" "${VDIR}/client.key"
  install -m 600 "${d}/vault.env" "${VDIR}/vault.env"
  vault_login || return 1
  vault_read_startup || return 1
  python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("SECRET_KEY") else 1)' "${SCRATCH}/startup.json" \
    || { echo "Vault holds no XPAM secrets for this installation" >&2; return 1; }
  vault_logout
  write_run_files
  install_boot_service
  set_vault_config
  echo_check "secrets read from Vault into memory (${RUN}); config.txt holds none"
}

cmd_local() { # a hardened Vault on this server (the kit with --local) and XPAM connected to it
  if secrets_from_vault; then echo "  already connected to Vault (xpamctl vault status)"; return 0; fi
  [[ -f /opt/xpam-vault/kit.env ]] && { log_error "/opt/xpam-vault already holds a Vault"; return 1; }
  local ip subnet
  ip=$(ip -o route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1)}')
  [[ -n "${ip}" ]] || ip=$(hostname -I | awk '{print $1}')
  subnet=$(get_config DOCKER_SUBNET 192.168.250.0/24)
  echo "  Vault on this server (${ip}), reachable by XPAM's containers (${subnet}); unsealed at every boot by this server."
  echo_warn "Someone with root on this server, or a copy of its disk, can still reach the secrets: move them to Vault servers of their own later (xpamctl vault connect)."
  export XPAM_VAULT_BUNDLE_PASSPHRASE="$(random_str 32)"
  XPAM_DOCKER_SUBNET="${subnet}" bash "${PROJECT_DIR}/vault/xpam-vault.sh" init --local --nodes "${ip}" --xpam "${ip}" \
    || { log_error "The local Vault could not be set up"; return 1; }
  if ! cmd_connect "/opt/xpam-vault/out/xpam-vault-${ip}.enc" -y; then
    # (the Vault exists; the bundle's passphrase was random and is not kept: it is needed to try again)
    log_error "XPAM could not be connected to the local Vault. Fix the cause, then: xpamctl vault connect /opt/xpam-vault/out/xpam-vault-${ip}.enc"
    echo "  Bundle passphrase (shown once; delete the bundle afterwards): ${XPAM_VAULT_BUNDLE_PASSPHRASE}"
    return 1
  fi
  shred -u /opt/xpam-vault/out/*.enc 2>/dev/null || rm -f /opt/xpam-vault/out/*.enc
}

core_manage() { # args — manage.py in XPAM's core container (stdin passed on)
  docker exec -i xpam_core bash -c 'cd /opt/jumpserver/apps && python manage.py "$@" 2>/dev/null' _ "$@"
}

cmd_add_connection() { # name type <settings.json | --bundle xpam-vault-IP.enc> — a further vault, managed here
  local name=$1 vtype=$2 src=$3 file=${4:-}
  [[ -n "${name}" && -n "${vtype}" && -n "${src}" ]] || {
    echo "usage: xpamctl vault add-connection <name> <hcp|cyberark|delinea|gcp|aws|azure|openbao> <settings.json>"
    echo "       xpamctl vault add-connection <name> hcp --bundle <xpam-vault-IP.enc>   (another Vault of the kit)"
    return 2; }
  scratch
  if [[ "${src}" == "--bundle" ]]; then
    [[ "${vtype}" == hcp && -f "${file}" ]] || { log_error "--bundle: a kit bundle for an hcp connection"; return 1; }
    export XV_BUNDLE_PW="$(passphrase_from XPAM_VAULT_BUNDLE_PASSPHRASE "Bundle passphrase")"
    local d; d=$(mktemp -d "${SCRATCH}/c.XXXX")
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass env:XV_BUNDLE_PW -in "${file}" 2>/dev/null | tar xzf - -C "${d}" 2>/dev/null
    [[ -f "${d}/vault.env" ]] || { log_error "Wrong bundle passphrase (or not a kit bundle)"; return 1; }
    python3 - "${d}" > "${SCRATCH}/conn.json" <<'PY'
import json, sys
d = sys.argv[1]
env = dict(l.strip().split('=', 1) for l in open(f'{d}/vault.env') if '=' in l)
print(json.dumps({
    'VAULT_HCP_HOST': env['VAULT_ADDRS'], 'VAULT_HCP_AUTH': 'cert', 'VAULT_HCP_CERT_ROLE': env['VAULT_ROLE'],
    'VAULT_HCP_MOUNT_POINT': env['VAULT_ACCOUNT_MOUNT'], 'VAULT_HCP_CA_PEM': open(f'{d}/ca.crt').read(),
    'VAULT_HCP_CLIENT_CERT_PEM': open(f'{d}/client.crt').read(), 'VAULT_HCP_CLIENT_KEY_PEM': open(f'{d}/client.key').read(),
}))
PY
    rm -rf "${d}"
  else
    [[ -f "${src}" ]] || { log_error "No such settings file: ${src}"; return 1; }
    cp "${src}" "${SCRATCH}/conn.json"
  fi
  core_manage xpam_vault_connection add --name "${name}" --type "${vtype}" --test --update < "${SCRATCH}/conn.json" \
    || { log_error "The connection was not added (its test failed, or wrong settings)"; return 1; }
  rm -f "${SCRATCH}/conn.json"
  echo_check "${name}: usable in System settings → Vault → Storage rules (and as a mirror)"
  [[ "${src}" != "--bundle" ]] && echo "  Delete the settings file: shred -u ${src}"
  return 0
}

cmd_rotation() { # daily|weekly|monthly|off — how often the data key rotates (no downtime)
  local period=$1 hours
  case "${period}" in
    daily) hours=24h ;; weekly) hours=168h ;; monthly) hours=720h ;; off) hours=0 ;;
    *) echo "usage: xpamctl vault rotation daily|weekly|monthly|off"; return 2 ;;
  esac
  set_config XPAM_DATA_KEY_ROTATION "${period}"
  if [[ "$(get_config XPAM_DATA_KEY)" == transit ]]; then
    XV_P="${hours}" docker exec -i -e XV_P xpam_core bash -c 'cd /opt/jumpserver/apps && python manage.py shell 2>/dev/null' <<'PY' \
      || { log_error "Vault did not accept the rotation period"; return 1; }
import os
from common.db import datakey
datakey.transit.set_config(auto_rotate_period=os.environ['XV_P'])
print(datakey.transit.info().get('auto_rotate_period'))
PY
  fi
  echo_check "data key rotation: ${period} (re-encryption runs every night; XPAM keeps running)"
}

cmd_data_key() { # local|legacy — without Vault: a versioned keyring in the database, rotated on schedule
  local p=$1
  [[ "${p}" == local || "${p}" == legacy ]] || { echo "usage: xpamctl vault data-key local|legacy"; return 2; }
  secrets_from_vault && { log_error "Connected to Vault: the data key is in Vault (Transit)"; return 1; }
  set_config XPAM_DATA_KEY "${p}"
  (cd "${PROJECT_DIR}" && bash ./xpamctl.sh restart >/dev/null 2>&1)
  local i
  for i in $(seq 1 60); do docker ps --format '{{.Names}} {{.Status}}' | grep -q '^xpam_core .*(healthy)' && break; sleep 5; done
  reencrypt_with_current_key
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
  if keep_db_copy; then echo "  database copy   yes (account secrets in Vault and the database: xpamctl vault keep-db-copy off)"
  else echo "  database copy   no (xpamctl vault keep-db-copy on)"; fi
}

cmd_verify() { # proves the connection is encrypted and XPAM's access is what it should be
  scratch
  secrets_from_vault || { echo "  not connected to Vault"; return 1; }
  local ok=0 bad=0 addr host port out days
  v() { if eval "$2"; then echo "  PASS  $1"; ok=$((ok+1)); else echo "  FAIL  $1"; bad=$((bad+1)); fi; }
  echo "  Encryption (each Vault server)"
  for addr in $(venv VAULT_ADDRS | tr ',' ' '); do
    host=${addr#https://}; host=${host%%/*}; port=${host##*:}; host=${host%:*}
    out=$(timeout 15 openssl s_client -connect "${host}:${port}" -servername "${host}" -tls1_3 -verify_return_error \
      -CAfile "${VDIR}/ca.crt" -cert "${VDIR}/client.crt" -key "${VDIR}/client.key" </dev/null 2>&1)
    v "${host}: TLS 1.3 ($(grep -m1 -oE 'TLS_[A-Z0-9_]+' <<<"${out}" || echo '?'))" "grep -q 'Protocol *: TLSv1.3\|New, TLSv1.3' <<<\"\${out}\""
    v "${host}: its certificate is signed by the kit CA and names this address" "grep -q 'Verify return code: 0 (ok)' <<<\"\${out}\""
    days=$(( ( $(date -d "$(sed -n '/BEGIN CERT/,/END CERT/p' <<<"${out}" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)" +%s 2>/dev/null || date +%s) - $(date +%s) ) / 86400 ))
    v "${host}: its certificate is valid for ${days} more days" "[[ ${days} -gt 30 ]]"
    v "${host}: TLS 1.2 is refused" "! timeout 15 openssl s_client -connect ${host}:${port} -tls1_2 -CAfile ${VDIR}/ca.crt -cert ${VDIR}/client.crt -key ${VDIR}/client.key </dev/null 2>&1 | grep 'Verify return code: 0' >/dev/null"
    v "${host}: without a client certificate nothing is answered" "[[ \$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --cacert ${VDIR}/ca.crt ${addr}/v1/sys/health) == 000 ]]"
  done
  days=$(( ( $(date -d "$(openssl x509 -noout -enddate -in "${VDIR}/client.crt" | cut -d= -f2)" +%s) - $(date +%s) ) / 86400 ))
  v "this server's client certificate is valid for ${days} more days" "[[ ${days} -gt 30 ]]"
  echo "  Vault and XPAM's access"
  v "Vault is unsealed and does not reveal its version" "[[ \$(vcurl sys/health) == 200 ]] && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if not d[\"sealed\"] and not d.get(\"version\") else 1)' ${SCRATCH}/out"
  v "login with this server's certificate" "vault_login"
  if [[ -s "${SCRATCH}/token.hdr" ]]; then
    vcurl auth/token/lookup-self -H @"${SCRATCH}/token.hdr" >/dev/null; cp "${SCRATCH}/out" "${SCRATCH}/self.json"
    v "the token has only XPAM's policy (no default, no root)" "python3 -c 'import json,sys; p=json.load(open(sys.argv[1]))[\"data\"][\"policies\"]; sys.exit(0 if p == [sys.argv[2]] else 1)' ${SCRATCH}/self.json $(venv VAULT_CLUSTER)"
    v "the token lasts at most an hour" "python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))[\"data\"]; sys.exit(0 if 0 < d[\"ttl\"] <= 3600 else 1)' ${SCRATCH}/self.json"
    v "the token works only from this server's address" "python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))[\"data\"]; sys.exit(0 if d.get(\"bound_cidrs\") else 1)' ${SCRATCH}/self.json"
    v "XPAM cannot list Vault's mounts" "[[ \$(vcurl sys/mounts -H @${SCRATCH}/token.hdr) == 403 ]]"
    v "XPAM cannot create tokens" "[[ \$(vcurl auth/token/create -X POST -H @${SCRATCH}/token.hdr -d '{}') == 403 ]]"
    v "XPAM cannot touch the audit log" "[[ \$(vcurl sys/audit -H @${SCRATCH}/token.hdr) == 403 ]]"
    v "XPAM cannot destroy the history of its startup secrets" "[[ \$(vcurl $(venv VAULT_CLUSTER)-startup/destroy/config -X POST -H @${SCRATCH}/token.hdr -d '{\"versions\":[1]}') == 403 ]]"
    vault_logout
  fi
  echo "  This server"
  local key left=""
  for key in ${XPAM_VAULT_SECRET_KEYS}; do [[ -n "$(config_value "${key}")" ]] && left+=" ${key}"; done
  v "config.txt holds no secret${left:+ (left:${left})}" "[[ -z '${left}' ]]"
  v "the secrets are in memory only (tmpfs)" "findmnt -no FSTYPE --target ${RUN} | grep -q tmpfs"
  local sk
  # shellcheck disable=SC2034  # (read inside the checks below)
  sk=$(get_config SECRET_KEY)
  # (the key goes to grep through a file descriptor, never on a command line; no -q: grep must read all, or a
  # match would end the pipe early and "pipefail" would turn a found key into a pass)
  v "no container holds SECRET_KEY in its settings" "[[ -n \"\${sk}\" ]] && ! docker ps -q | xargs -r docker inspect | grep -F -f <(printf '%s\\n' \"\${sk}\") >/dev/null"
  v "XPAM's own client: TLS 1.3, the kit CA only, login and store OK" "[[ \$(docker exec -i xpam_core bash -c 'cd /opt/jumpserver/apps && python manage.py shell' 2>/dev/null <<'PY' | tail -1
import ssl
from accounts.backends import vault_client
vault_client.type
backend = vault_client._wrapped
ok, err = backend.is_active()
print(ok and backend.client.session.adapters['https://'].ctx.minimum_version == ssl.TLSVersion.TLSv1_3)
PY
) == True ]]"
  local n
  n=$(core_exec <<'PY' | tail -1
from accounts.models import Account
from accounts.models.mixins.vault import VAULT_SAVED_SECRET_MARK
print(sum(1 for o in Account.objects.only('id', '_secret').iterator() if o._secret and o._secret != VAULT_SAVED_SECRET_MARK))
PY
)
  v "the database keeps no account secret" "[[ '${n}' == 0 ]]"
  echo
  echo "  ${ok} passed, ${bad} failed"
  [[ ${bad} -eq 0 ]]
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
  echo_yellow "1. Account secrets back into the database, everything under SECRET_KEY again"
  to_legacy_data_key >/dev/null || { log_error "The secrets could not be read from Vault: nothing changed"; return 1; }
  echo_yellow "2. Secrets back into config.txt"
  local line key value
  set_config XPAM_SECRETS_FROM_VAULT 0
  while IFS= read -r line; do
    key=${line%%=*}; value=${line#*=}
    set_config "${key}" "${value}"
  done < "${RUN}/all.env"
  # every secret must be in config.txt before the memory copy and the boot service are removed
  local missing=""
  while IFS= read -r line; do
    key=${line%%=*}; value=${line#*=}
    [[ "$(config_value "${key}")" == "${value}" ]] || missing+=" ${key}"
  done < "${RUN}/all.env"
  if [[ -n "${missing}" ]]; then
    set_config XPAM_SECRETS_FROM_VAULT 1
    log_error "These secrets could not be written to ${CONFIG_FILE}:${missing}. Nothing else was changed; the secrets are still in Vault."
    return 1
  fi
  set_config VAULT_ENABLED false
  set_config VAULT_LOCKED false
  set_config VAULT_KEEP_DB_COPY false
  set_config XPAM_DATA_KEY legacy
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
KEEP_DB_COPY=""
args=()
for a in "$@"; do if [[ "${a}" == --keep-db-copy ]]; then KEEP_DB_COPY=1; else args+=("${a}"); fi; done
set -- "${args[@]}"
case "${1:-}" in
  connect) cmd_connect "${2:-}" "${3:-}" ;;
  status) cmd_status ;;
  fetch) cmd_fetch "${2:-}" ;;
  put) cmd_put "${2:-}" ;;
  disconnect) cmd_disconnect "${2:-}" ;;
  verify) cmd_verify ;;
  attach) cmd_attach "${2:-}" ;;
  local) cmd_local ;;
  rotation) cmd_rotation "${2:-}" ;;
  data-key) cmd_data_key "${2:-}" ;;
  keep-db-copy) cmd_keep_db_copy "${2:-}" ;;
  add-connection) cmd_add_connection "${2:-}" "${3:-}" "${4:-}" "${5:-}" ;;
  list-connections) core_manage xpam_vault_connection list ;;
  remove-connection) core_manage xpam_vault_connection remove --name "${2:-}" ;;
  *) sed -n '3,/^# After/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
