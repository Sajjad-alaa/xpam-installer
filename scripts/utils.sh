#!/usr/bin/env bash
#

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

. "${BASE_DIR}/const.sh"
. "${BASE_DIR}/gists/common.sh"
. "${BASE_DIR}/gists/conf.sh"
. "${BASE_DIR}/gists/openbao.sh"
. "${BASE_DIR}/gists/jdmc.sh"
. "${BASE_DIR}/gists/kotl.sh"
. "${BASE_DIR}/gists/image.sh"
. "${BASE_DIR}/gists/service.sh"

# XPAM: this server's ID for a cluster licence — its hardware, exactly as XPAM computes it (xpack get_server_id)
function xpam_server_id() {
  local f v=''
  for f in /sys/class/dmi/id/product_uuid /etc/machine-id /var/lib/dbus/machine-id; do
    v=$(tr -d '[:space:]' < "${f}" 2>/dev/null)
    [[ -n "${v}" && "${v}" != 00000000-0000-0000-0000-000000000000 ]] && break
    v=''
  done
  printf 'SRV-%s\n' "$(printf '%s' "XPAM-SERVER:${v:-default-hardware-uuid}" | sha256sum | tr 'a-f' 'A-F' \
    | sed -E 's/^(.{4})(.{4})(.{4}).*/\1-\2-\3/')"
}
# (high availability shows every server's ID: Patroni carries it as a tag)
XPAM_SERVER_ID=$(xpam_server_id)
export XPAM_SERVER_ID

# XPAM: with secrets in Vault, nothing may run without them (an upgrade would otherwise create new ones)
if [[ -z "${XPAM_VAULT_NO_GUARD:-}" ]] && secrets_from_vault && [[ ! -s "${XPAM_SECRETS_RUN_DIR}/all.env" ]]; then
  if ! XPAM_VAULT_NO_GUARD=1 timeout 120 bash "${BASE_DIR}/vault.sh" fetch >/dev/null 2>&1; then
    echo_red "XPAM's secrets are in Vault and could not be read (Vault unreachable or this server's login refused)."
    echo_red "Check: systemctl status xpam-secrets / xpamctl vault status"
    exit 1
  fi
fi

