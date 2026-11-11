#!/bin/bash
# XPAM gateway: prepares the nginx configuration when the container starts (run by /docker-entrypoint.sh).
# Settings come from the environment (compose/gateway.yml): SERVER_NAME, HTTPS_PORT, USE_IPV6, USE_LB,
# CLIENT_MAX_BODY_SIZE, SSL_CERTIFICATE / SSL_CERTIFICATE_KEY, GZIP and the services' switches.

TEMPLATE=/etc/nginx/sites-enabled/https_server.conf
CONFIG=/etc/nginx/conf.d/https_server.conf
CERT_DIR=/etc/nginx/cert

config_nginx() {
  if [ "${USE_IPV6}" == "1" ]; then
    sed -i "s@# listen \[::\]:80;@listen \[::\]:80;@g" "${CONFIG}"
    sed -i "s@# listen \[::\]:51980;@listen \[::\]:51980;@g" /etc/nginx/conf.d/default.conf
  fi

  if [ -n "${SERVER_NAME}" ]; then
    SERVER_NAME=$(echo "$SERVER_NAME" | sed 's/,/ /g; s/ *$//')
    sed -i "s@# server_name .*;@server_name ${SERVER_NAME};@g" "${CONFIG}"
  fi

  if [ -n "${CLIENT_MAX_BODY_SIZE}" ]; then
    sed -i "s@client_max_body_size .*;@client_max_body_size ${CLIENT_MAX_BODY_SIZE};@g" /etc/nginx/conf.d/*.conf
  fi

  # Only an explicit USE_LB=0 means a trusted proxy is in front of this server. Otherwise this server is the
  # trust boundary and discards the X-Forwarded-For values a client sends.
  if [ "${USE_LB:-1}" == "0" ]; then
    sed -i 's@proxy_set_header X-Forwarded-For .*;@proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;@g' "${CONFIG}"
  else
    sed -i 's@proxy_set_header X-Forwarded-For .*;@proxy_set_header X-Forwarded-For $remote_addr;@g' "${CONFIG}"
  fi
}

# The certificate pair in /etc/nginx/cert (mounted from the installation's configuration). Without one the server
# makes its own self-signed pair for this container: every installation has a different key.
config_certificate() {
  cert_name=${SSL_CERTIFICATE:-server.crt}
  key_name=${SSL_CERTIFICATE_KEY:-server.key}
  if [[ ! -f "${CERT_DIR}/${cert_name}" || ! -f "${CERT_DIR}/${key_name}" ]]; then
    if [[ -n "${SSL_CERTIFICATE}" || -n "${SSL_CERTIFICATE_KEY}" ]]; then
      echo "Warning: certificate or private key not found: ${CERT_DIR}/${cert_name}, ${CERT_DIR}/${key_name}"
      echo "Falling back to server.crt and server.key"
    fi
    cert_name=server.crt
    key_name=server.key
  fi
  cert_file=${CERT_DIR}/${cert_name}
  key_file=${CERT_DIR}/${key_name}

  if [[ ! -f "${cert_file}" && ! -f "${key_file}" ]]; then
    echo "No certificate in ${CERT_DIR}: creating a self-signed one for this container"
    mkdir -p /etc/nginx/cert-generated
    cert_file=/etc/nginx/cert-generated/server.crt
    key_file=/etc/nginx/cert-generated/server.key
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout "${key_file}" -out "${cert_file}" \
      -subj "/O=XPAM/CN=${SERVER_NAME%%[ ,]*}" 2>/dev/null \
      || openssl req -x509 -nodes -days 3650 -newkey rsa:2048 -keyout "${key_file}" -out "${cert_file}" -subj "/O=XPAM/CN=localhost" 2>/dev/null \
      || { echo "The self-signed certificate could not be created"; exit 1; }
    chmod 600 "${key_file}"
  elif [[ ! -f "${cert_file}" || ! -f "${key_file}" ]]; then
    echo "The certificate and its private key must both exist: ${cert_file}, ${key_file}"
    exit 1
  fi
}

config_https() {
  cp -f "${TEMPLATE}" "${CONFIG}"
  config_certificate
  config_nginx

  if [[ -n "${HTTPS_PORT}" && "${HTTPS_PORT}" != "0" ]]; then
    if [ "${HTTPS_PORT}" == "443" ]; then
      redirect_url='https://$host$request_uri'
    else
      redirect_url="https://\$host:${HTTPS_PORT}\$request_uri"
    fi
    sed -i "s@  # HTTPS_REDIRECT@  return 307 ${redirect_url};@g" "${CONFIG}"
  fi

  if [ "${USE_IPV6}" == "1" ]; then
    sed -i "s@# listen \[::\]:443 ssl;@listen [::]:443 ssl;@g" "${CONFIG}"
  fi

  sed -i "s@ssl_certificate .*;@ssl_certificate ${cert_file};@g" "${CONFIG}"
  sed -i "s@ssl_certificate_key .*;@ssl_certificate_key ${key_file};@g" "${CONFIG}"
}

# A service that is switched off has no route
disable_route() {
  if [ -f "/etc/nginx/includes/$1.conf" ]; then
    mv "/etc/nginx/includes/$1.conf" "/etc/nginx/includes/$1.conf.disabled"
  fi
}

config_services() {
  [ "${CORE_ENABLED}" == "0" ] && disable_route core
  [ "${SECURECONNECTION_ENABLED}" == "0" ] && disable_route secureconnection
  [ "${WEBCONNECTOR_ENABLED}" == "0" ] && disable_route webconnector
  [ "${AI_ENABLED}" == "0" ] && disable_route ai
  return 0
}

config_https
config_services

# (log rotation)
if [ -f /etc/init.d/cron ]; then
  /etc/init.d/cron start
fi

if [[ "${GZIP}" == "off" ]]; then
  sed -i "s@gzip .*;@gzip ${GZIP};@g" /etc/nginx/nginx.conf
fi
