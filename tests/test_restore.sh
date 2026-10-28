#!/usr/bin/env bash

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helper.sh"

test_dir="${TEST_TMP_ROOT}/restore"
mkdir -p "${test_dir}"
export JS_CONFIG_DIR="${test_dir}"
cp "${TEST_ROOT}/config-example.txt" "${test_dir}/config.txt"

. "${TEST_ROOT}/scripts/6_db_restore.sh" ''

# A truncated gzip must make the MySQL restore fail (the mysql client at the end of the pipe would succeed)
db_images=test-image
DB_FILE="${test_dir}/dump.sql.gz"
printf 'CREATE TABLE t (id int);\n' | gzip >"${DB_FILE}"
head -c 30 "${DB_FILE}" >"${test_dir}/cut.sql.gz"
docker() {
  # run the restore command here, with "mysql" replaced by one that always succeeds
  local arg cmd=''
  for arg in "$@"; do cmd=${arg}; done
  mysql() { cat >/dev/null; }
  export -f mysql
  DB_FILE="${DB_FILE_UNDER_TEST}" DB_HOST=h DB_PORT=1 DB_USER=u DB_PASSWORD=p DB_NAME=n bash -c "${cmd}"
}
DB_FILE_UNDER_TEST="${DB_FILE}"
restore_mysql || fail 'a complete gzip dump must restore'
DB_FILE_UNDER_TEST="${test_dir}/cut.sql.gz"
if restore_mysql 2>/dev/null; then
  fail 'a truncated gzip dump must fail the MySQL restore'
fi
printf 'PASS: a truncated MySQL dump fails the restore\n'

# The current database is backed up before it is replaced; a failed backup stops the restore unless confirmed
backup_calls=0
bash() { backup_calls=$((backup_calls + 1)); return "${backup_status}"; }
backup_status=0
backup_before_restore
assert_eq 1 "${backup_calls}" 'restore must back up the current database first'
SKIP_BACKUP_DB=1 backup_before_restore
assert_eq 1 "${backup_calls}" 'SKIP_BACKUP_DB=1 skips the safety backup'
backup_status=1
read_from_input() { export "$1"=n; }
if backup_before_restore >/dev/null; then
  fail 'a failed safety backup must stop the restore unless confirmed'
fi
read_from_input() { export "$1"=y; }
backup_before_restore >/dev/null || fail 'the administrator may restore without a safety backup'
unset -f bash
printf 'PASS: restore takes a safety backup first\n'
