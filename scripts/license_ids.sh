#!/usr/bin/env bash
#
# XPAM: the IDs a licence is issued for — the cluster's (its database seed, shared by every server of a high
# availability cluster) and this server's (its hardware). Works on a standby too (XPAM's services stopped):
# the database copy has the same seed.
#   xpamctl license-ids
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
. "${BASE_DIR}/utils.sh"

function main() {
  local server cluster seed
  server=$(xpam_server_id)
  if docker ps --format '{{.Names}}' | grep -qx xpam_core; then
    cluster=$(docker exec -i xpam_core bash -c 'cd /opt/jumpserver/apps && python manage.py shell 2>/dev/null' \
      <<<'from xpack.utils import get_cluster_id; print("CLUSTER", get_cluster_id())' | awk '/^CLUSTER /{print $2}' | tail -1)
  fi
  if [[ -z "${cluster}" ]] && docker ps --format '{{.Names}}' | grep -qx xpam_postgresql; then
    # (the same bytes core reads: the setting's stored value)
    seed=$(docker exec xpam_postgresql psql -U "$(get_config DB_USER)" -d "$(get_config DB_NAME)" -Atqc \
      "select value from settings_setting where name='INSTALLATION_SEED'" 2>/dev/null | head -1)
    [[ -n "${seed}" ]] || seed='XPAM-DEFAULT-SEED'
    cluster="CL-$(printf '%s' "XPAM-CLUSTER:${seed}" | sha256sum | tr 'a-f' 'A-F' | sed -E 's/^(.{4})(.{4})(.{4})(.{4}).*/\1-\2-\3-\4/')"
  fi
  echo "Cluster ID:      ${cluster:-unknown (the XPAM database is not running here)}"
  echo "This server ID:  ${server}"
  if is_ha_enabled; then
    echo "High availability: run this on every server and send all the IDs to your vendor (one licence for the cluster)."
  fi
}

main "$@"
