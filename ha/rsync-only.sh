#!/bin/sh
# XPAM high availability: the other server's SSH key may only copy files into XPAM's data folder
# (authorized_keys: command="/opt/xpam-installer/ha/rsync-only.sh <data-dir>",restrict,from="<peer>").
# Only the exact command the HA agent's rsync sends is accepted: `rsync --server <short flags> [--timeout=N]
# [--partial] . <data-dir>[/...]` — no other option (e.g. --log-file=, --temp-dir=) and one destination.
data=$1
deny() {
  echo "XPAM: only file copies into ${data} are allowed" >&2
  exit 1
}
set -f  # (the command's words are not file patterns)
# shellcheck disable=SC2086
set -- $SSH_ORIGINAL_COMMAND
[ "$1" = rsync ] && [ "$2" = --server ] || deny
shift 2
while [ $# -gt 0 ] && [ "$1" != . ]; do
  case "$1" in
    --partial | --timeout=[0-9]*) ;;
    --*) deny ;;
    -*[!A-Za-z.]*) deny ;;  # (short flags only, e.g. -logDtpre.iLsfxCIvu: no attached paths)
    -?*) ;;
    *) deny ;;
  esac
  shift
done
[ "$1" = . ] && [ $# -eq 2 ] || deny
case "$2" in
  *..*) deny ;;
  "${data}" | "${data}"/*) ;;
  *) deny ;;
esac
# shellcheck disable=SC2086
exec $SSH_ORIGINAL_COMMAND
