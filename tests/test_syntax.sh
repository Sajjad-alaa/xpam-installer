#!/usr/bin/env bash

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

# Every installer script must at least parse: a quoting slip makes a whole command (for example
# "xpamctl license-ids") unusable and no other test notices.
for script in "${TEST_ROOT}/quick_start.sh" "${TEST_ROOT}/xpamctl.sh" \
  "${TEST_ROOT}"/scripts/*.sh "${TEST_ROOT}"/scripts/gists/*.sh; do
  bash -n "${script}" || fail "syntax error in ${script}"
done
printf 'PASS: every installer script parses\n'
