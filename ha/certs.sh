#!/usr/bin/env bash
# XPAM high availability: a private CA and the cluster certificates.
#   certs.sh <out-dir> --servers <ip>,<ip>[,...] [--witness <ip>]
#   certs.sh <out-dir> <ip-a> <ip-b> <ip-witness>        (two servers and a witness, as before)
# node.crt/key     every XPAM server (CN xpam-node): PostgreSQL replication, Patroni's API, Redis replication,
#                  etcd client and member; the vote (etcd) grants read/write on XPAM's records to this name only
# witness.crt/key  the witness (CN xpam-witness): an etcd member (votes) with no rights on the records
# client.crt/key   Patroni's client certificate for the vote (no name; the xpam-node password identifies it)
# app.crt/key      XPAM's containers in active-active (CN xpam-app): log in to the database and Redis of the
#                  other servers; no name the vote knows, so no rights there
# ca.crt/ca.key    the CA (ca.key is encrypted with the cluster passphrase by 'xpamctl ha' right after)
set -euo pipefail
out=$1; shift
servers=''; w=''
if [[ "${1:-}" == --* ]]; then
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --servers) servers=$2; shift 2 ;;
      --witness) w=$2; shift 2 ;;
      *) echo "certs.sh: unknown option $1" >&2; exit 2 ;;
    esac
  done
else
  [[ $# -eq 3 ]] || { echo "usage: certs.sh <out-dir> --servers <ip>,<ip>[,...] [--witness <ip>]" >&2; exit 2; }
  servers="$1,$2"; w=$3
fi
[[ -n "${servers}" ]] || { echo "certs.sh: --servers is required" >&2; exit 2; }
umask 077
mkdir -p "$out"
# (a CA marked as one — key usage keyCertSign/cRLSign: Python 3.13+ verifies strictly, e.g. XPAM's containers in
# active-active connecting to the other servers' database and Redis)
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
  -subj "/CN=XPAM HA CA $(date +%Y%m%d%H%M%S)" -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" -addext "subjectKeyIdentifier=hash" \
  -keyout "$out/ca.key" -out "$out/ca.crt" 2>/dev/null
issue() { # name cn san
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=$2" \
    -keyout "$out/$1.key" -out "$out/$1.csr" 2>/dev/null
  printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth,clientAuth\nkeyUsage=digitalSignature,keyEncipherment\n' "$3" \
    > "$out/$1.ext"
  openssl x509 -req -in "$out/$1.csr" -CA "$out/ca.crt" -CAkey "$out/ca.key" -CAcreateserial -days 3650 \
    -extfile "$out/$1.ext" -out "$out/$1.crt" 2>/dev/null
  rm -f "$out/$1.csr" "$out/$1.ext"
}
issue node xpam-node "IP:127.0.0.1,DNS:localhost,DNS:postgresql$(printf ',IP:%s' ${servers//,/ })"
issue app xpam-app "DNS:xpam-app"
if [[ -n "${w}" ]]; then
  issue witness xpam-witness "IP:127.0.0.1,IP:$w"
fi
# Patroni's client certificate for the vote: no common name (etcd's HTTP gateway refuses a named client
# certificate once permissions are on); Patroni is identified by the xpam-node account's password
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/O=XPAM HA client" \
  -keyout "$out/client.key" -out "$out/client.csr" 2>/dev/null
printf 'extendedKeyUsage=clientAuth\nkeyUsage=digitalSignature\n' > "$out/client.ext"
openssl x509 -req -in "$out/client.csr" -CA "$out/ca.crt" -CAkey "$out/ca.key" -CAcreateserial -days 3650 \
  -extfile "$out/client.ext" -out "$out/client.crt" 2>/dev/null
rm -f "$out/client.csr" "$out/client.ext"
rm -f "$out/ca.srl"
