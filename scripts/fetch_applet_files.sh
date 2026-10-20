#!/usr/bin/env bash
#
# XPAM: put the files Windows publishing hosts (applet hosts) download during setup on this server,
# so /download/ never has to fall back to jumpserver.org. Every file is checked against
# applet-files.sha256 (in this folder); an unknown file is refused unless --trust-on-first-use, which
# records its checksum so later downloads must match it.
set -o pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
. "${BASE_DIR}/utils.sh"

SOURCE=${APPLET_FILES_SOURCE:-https://static.jumpserver.org/download/applets}
FILES=("Tinker_Installer_v0.3.0.exe" "jumpserver-tinker-python-3.11.11-win64.zip")
SUMS="${BASE_DIR}/applet-files.sha256"

function fetch_main() {
  local tofu=$1 dest tmp file want got
  dest="$(get_config VOLUME_DIR)/web/applets"
  mkdir -p "${dest}" || return 1
  touch "${SUMS}"
  for file in "${FILES[@]}"; do
    want=$(awk -v f="${file}" '$2 == f {print $1}' "${SUMS}")
    if [[ -z "${want}" && "${tofu}" != "--trust-on-first-use" ]]; then
      log_error "${file}: no known checksum in ${SUMS}; add the vendor's SHA-256 there, or run with --trust-on-first-use"
      return 1
    fi
    tmp=$(mktemp "${dest}/.${file}.XXXXXX") || return 1
    echo "Downloading ${file} ..."
    if ! curl -fSL --proto '=https' --tlsv1.2 --retry 3 -o "${tmp}" "${SOURCE}/${file}"; then
      rm -f "${tmp}"; log_error "Download of ${file} failed"; return 1
    fi
    got=$(sha256sum "${tmp}" | awk '{print $1}')
    if [[ -n "${want}" && "${got}" != "${want}" ]]; then
      rm -f "${tmp}"; log_error "${file}: checksum mismatch (expected ${want}, got ${got}); not installed"; return 1
    fi
    if [[ -z "${want}" ]]; then
      echo "${got}  ${file}" >> "${SUMS}"
      log_warn "${file}: checksum ${got} recorded (trust on first use); compare it with the vendor's published value"
    fi
    chmod 644 "${tmp}" && mv -f "${tmp}" "${dest}/${file}" || return 1
    echo_green "  ${file} ok"
  done
  echo "Applet host files are in ${dest} (served at /download/applets/)"
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  fetch_main "$@"
fi
