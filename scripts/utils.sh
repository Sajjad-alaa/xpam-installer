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

# XPAM: with secrets in Vault, nothing may run without them (an upgrade would otherwise create new ones)
if [[ -z "${XPAM_VAULT_NO_GUARD:-}" ]] && secrets_from_vault && [[ ! -s "${XPAM_SECRETS_RUN_DIR}/all.env" ]]; then
  if ! XPAM_VAULT_NO_GUARD=1 timeout 120 bash "${BASE_DIR}/vault.sh" fetch >/dev/null 2>&1; then
    echo_red "XPAM's secrets are in Vault and could not be read (Vault unreachable or this server's login refused)."
    echo_red "Check: systemctl status xpam-secrets / xpamctl vault status"
    exit 1
  fi
fi

