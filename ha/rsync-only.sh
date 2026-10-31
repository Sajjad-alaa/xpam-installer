#!/bin/sh
# XPAM high availability: the other server's SSH key may only copy files into XPAM's data folder
# (authorized_keys: command="/opt/xpam-installer/ha/rsync-only.sh <data-dir>",restrict,from="<peer>").
# Only the exact command the HA agent's rsync sends is accepted: `rsync --server <short flags> [--timeout=N]
# [--partial] . <data-dir>[/...]` — no other option (e.g. --log-file=, --temp-dir=) and one destination.
# Symlinks: the copy cannot be used to write outside the folder through a link. Received links that point
# outside the folder (absolute, or climbing out with ..) are not created (--safe-links), and the destination is
# resolved (readlink -f) and must stay inside the folder. (--munge-links is not used: the servers copy to each
# other, so every round trip would add its prefix to every link.)
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
opts=''
while [ $# -gt 0 ] && [ "$1" != . ]; do
  case "$1" in
    --partial | --timeout=[0-9]*) ;;
    --*) deny ;;
    -*[!A-Za-z.]*) deny ;;  # (short flags only, e.g. -logDtpre.iLsfxCIvu: no attached paths)
    -?*)
      # only the options the HA agent's rsync -a [--update] sends; what follows the e is the client's protocol
      # capabilities, not options. (e.g. -K would follow a link already in the folder out of it, -L copy through it)
      flags=${1#-}
      case "${flags%%e*}" in
        *[!ulogDtpr]*) deny ;;
      esac
      ;;
    *) deny ;;
  esac
  opts="${opts} $1"
  shift
done
[ "$1" = . ] && [ $# -eq 2 ] || deny
case "$2" in
  *..*) deny ;;
  "${data}" | "${data}"/*) ;;
  *) deny ;;
esac
# (a link already in the folder must not lead the copy elsewhere: the real path of the destination is checked too)
root=$(readlink -f -- "${data}") || deny
real=$(readlink -f -- "$2") || deny
case "${real}" in
  "${root}" | "${root}"/*) ;;
  *) deny ;;
esac
# shellcheck disable=SC2086
exec rsync --server --safe-links ${opts} . "$2"
