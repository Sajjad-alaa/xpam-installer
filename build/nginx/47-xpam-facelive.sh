#!/bin/sh
# XPAM: the /ws/facelive/ route is there only when face recognition is on (FACELIVE_ENABLED, which the
# compose file takes from FACELIVE_ENABLED or FACE_RECOGNITION_ENABLED). Off: the path goes to core, which has no
# such socket (404), like before.
case "$(echo "${FACELIVE_ENABLED:-0}" | tr '[:upper:]' '[:lower:]')" in
  1|true|yes|on)
    echo "XPAM: /ws/facelive/ routes to the facelive container"
    ;;
  *)
    rm -f /etc/nginx/includes/facelive.conf
    ;;
esac
