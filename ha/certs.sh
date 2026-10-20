#!/usr/bin/env bash
# XPAM high availability: a private CA and one certificate for the cluster (etcd members, etcd clients,
# PostgreSQL replication), valid for the addresses of both servers and the witness.
#   certs.sh <out-dir> <ip-a> <ip-b> <ip-witness>
set -euo pipefail
out=$1; shift
[[ $# -eq 3 ]] || { echo "usage: certs.sh <out-dir> <ip-a> <ip-b> <ip-witness>" >&2; exit 2; }
umask 077
mkdir -p "$out"
san="IP:127.0.0.1,DNS:localhost,DNS:postgresql"
for ip in "$@"; do san+=",IP:${ip}"; done
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 -subj "/CN=XPAM HA CA" \
  -keyout "$out/ca.key" -out "$out/ca.crt" 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=xpam-ha" \
  -keyout "$out/node.key" -out "$out/node.csr" 2>/dev/null
printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth,clientAuth\nkeyUsage=digitalSignature,keyEncipherment\n' "$san" > "$out/ext.cnf"
openssl x509 -req -in "$out/node.csr" -CA "$out/ca.crt" -CAkey "$out/ca.key" -CAcreateserial -days 3650 \
  -extfile "$out/ext.cnf" -out "$out/node.crt" 2>/dev/null
rm -f "$out/node.csr" "$out/ext.cnf" "$out/ca.srl"
