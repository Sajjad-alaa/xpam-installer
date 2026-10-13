#!/usr/bin/env bash
# XPAM quick start: downloads the installer to /opt/xpam-installer and runs it.
#
#   curl -fsSL https://raw.githubusercontent.com/Sajjad-alaa/xpam-installer/xpam/quick_start.sh | bash
#
# Unattended (accept every default):   ... | AUTO_INSTALL=1 bash
# Private images without a prompt:     XPAM_REGISTRY_USER=<user> XPAM_REGISTRY_TOKEN=<token> in the environment

REPO=${XPAM_INSTALLER_REPO:-https://github.com/Sajjad-alaa/xpam-installer.git}
BRANCH=${XPAM_INSTALLER_BRANCH:-xpam}
TARGET=${XPAM_INSTALLER_DIR:-/opt/xpam-installer}

function fail() {
  echo -e "[\033[31m ERROR \033[0m] $*" >&2
  exit 1
}

function install_soft() {
  local package=$1
  echo "Installing ${package}"
  if command -v dnf &>/dev/null; then
    dnf -q -y install "${package}" &>/dev/null
  elif command -v yum &>/dev/null; then
    yum -q -y install "${package}" &>/dev/null
  elif command -v apt-get &>/dev/null; then
    [[ "${package}" == "gettext" ]] && package=gettext-base
    apt-get -qq update &>/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get -qqy install "${package}" &>/dev/null
  elif command -v zypper &>/dev/null; then
    zypper -q -n install "${package}" &>/dev/null
  else
    fail "${package} is missing, install it first"
  fi
}

function prepare_install() {
  local tool
  [[ "$(uname -s)" == "Linux" ]] || fail "XPAM is installed on a Linux server"
  [[ "$(id -u)" == "0" ]] || fail "Run this as root (or with sudo)"
  for tool in curl wget tar gettext git openssl; do
    command -v "${tool}" &>/dev/null || install_soft "${tool}" || fail "Could not install ${tool}"
  done
  command -v python3 &>/dev/null || command -v python &>/dev/null || install_soft python3
  command -v iptables &>/dev/null || install_soft iptables
  command -v sha256sum &>/dev/null || install_soft coreutils
}

function get_installer() {
  if [[ -d "${TARGET}/.git" ]]; then
    echo "Updating the installer in ${TARGET}"
    git -C "${TARGET}" pull --ff-only --quiet || echo "Could not update ${TARGET}; using the copy that is there"
  elif [[ -e "${TARGET}" ]]; then
    fail "${TARGET} exists but is not an XPAM installer checkout. Move it away and run this again."
  else
    echo "Downloading the installer to ${TARGET}"
    git clone --quiet --branch "${BRANCH}" "${REPO}" "${TARGET}" || fail "Could not download the installer from ${REPO}"
  fi
}

function run_installer() {
  cd "${TARGET}" || exit 1
  # When this script is piped into bash, the questions must still come from the keyboard
  if [[ ! -t 0 && "${AUTO_INSTALL:-}" != "1" ]]; then
    if (exec </dev/tty) 2>/dev/null; then
      exec </dev/tty
    else
      echo "No terminal available: accepting the default answers"
      export AUTO_INSTALL=1
    fi
  fi
  ./xpamctl.sh install
}

function main() {
  prepare_install
  get_installer
  run_installer
}

main
