#!/bin/sh
# XPAM: missing /download/ files are "not found" unless DOWNLOAD_FALLBACK=1 (then redirected to the
# upstream download site, as JumpServer does).
conf=/etc/nginx/includes/common.conf
if [ "${DOWNLOAD_FALLBACK:-0}" = "1" ]; then
  sed -i 's#try_files $uri =404;  \# xpam-download#try_files $uri @redirect_oss;  \# xpam-download#' "$conf"
  echo "XPAM: /download/ falls back to static.jumpserver.org (DOWNLOAD_FALLBACK=1)"
fi
