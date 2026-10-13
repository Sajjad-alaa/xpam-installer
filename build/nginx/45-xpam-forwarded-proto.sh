#!/bin/sh
# Runs after the stock start-up script has written the front server configuration.
# With a trusted load balancer in front (USE_LB=0), pass on the scheme it reports.
conf=/etc/nginx/conf.d/https_server.conf
if [ "${USE_LB:-1}" = "0" ] && [ -f "${conf}" ]; then
  sed -i 's@proxy_set_header X-Forwarded-Proto .*;@proxy_set_header X-Forwarded-Proto $xpam_client_proto;@g' "${conf}"
fi
