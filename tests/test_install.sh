#!/usr/bin/env bash

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

test_dir="${TEST_TMP_ROOT}/install"
mkdir -p "${test_dir}"
export JS_CONFIG_DIR="${test_dir}"
cp "${TEST_ROOT}/config-example.txt" "${test_dir}/config.txt"

. "${TEST_ROOT}/scripts/4_install_xpam.sh"

log_error() { :; }
set_config VOLUME_DIR "${test_dir}/volume"
set_config CURRENT_VERSION v0.0.1

# no database yet: an installation that stopped early may be run again with a newer installer
refuse_install_over_other_version || fail 'a server without a database may be installed again'

# a database of another XPAM version: "upgrade" (with its backup) is the way
mkdir -p "${test_dir}/volume/postgresql/data"
touch "${test_dir}/volume/postgresql/data/PG_VERSION"
if refuse_install_over_other_version; then
  fail 'install over another version with a database must be refused'
fi
XPAM_FORCE_INSTALL=1 refuse_install_over_other_version || fail 'XPAM_FORCE_INSTALL=1 overrides the check'
set_config CURRENT_VERSION "${VERSION}"
refuse_install_over_other_version || fail 'the same version may be installed again'
printf 'PASS: install is refused over a database of another version\n'
