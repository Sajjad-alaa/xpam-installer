#!/bin/sh
# XPAM high availability: the other server's SSH key may only copy files into XPAM's data folder
# (authorized_keys: command="/opt/xpam-installer/ha/rsync-only.sh <data-dir>",restrict,from="<peer>").
data=$1
case "$SSH_ORIGINAL_COMMAND" in
  *..*) ;;
  "rsync --server "*" . ${data}/"*|"rsync --server "*" . ${data}")
    # shellcheck disable=SC2086
    exec $SSH_ORIGINAL_COMMAND ;;
esac
echo "XPAM: only file copies into ${data} are allowed" >&2
exit 1
