#!/usr/bin/env bash
# XPAM high availability: a private CA and the cluster certificates.
#   certs.sh <out-dir> <ip-a> <ip-b> <ip-witness>
# node.crt/key     both servers (CN xpam-node): PostgreSQL replication, Patroni's API, Redis replication, etcd
#                  client and member; the vote (etcd) grants read/write on XPAM's records to this name only
# witness.crt/key  the witness (CN xpam-witness): an etcd member (votes) with no rights on the records
# client.crt/key   Patroni's client certificate for the vote (no name; the xpam-node password identifies it)
# ca.crt/ca.key    the CA (ca.key is encrypted with the cluster passphrase by 'xpamctl ha' right after)
set -euo pipefail
out=$1; shift
[[ $# -eq 3 ]] || { echo "usage: certs.sh <out-dir> <ip-a> <ip-b> <ip-witness>" >&2; exit 2; }
a=$1; b=$2; w=$3
umask 077
mkdir -p "$out"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
  -subj "/CN=XPAM HA CA $(date +%Y%m%d%H%M%S)" -keyout "$out/ca.key" -out "$out/ca.crt" 2>/dev/null
issue() { # name cn san
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=$2" \
    -keyout "$out/$1.key" -out "$out/$1.csr" 2>/dev/null
  printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth,clientAuth\nkeyUsage=digitalSignature,keyEncipherment\n' "$3" \
    > "$out/$1.ext"
  openssl x509 -req -in "$out/$1.csr" -CA "$out/ca.crt" -CAkey "$out/ca.key" -CAcreateserial -days 3650 \
    -extfile "$out/$1.ext" -out "$out/$1.crt" 2>/dev/null
  rm -f "$out/$1.csr" "$out/$1.ext"
}
issue node xpam-node "IP:127.0.0.1,DNS:localhost,DNS:postgresql,IP:$a,IP:$b"
issue witness xpam-witness "IP:127.0.0.1,IP:$w"
# Patroni's client certificate for the vote: no common name (etcd's HTTP gateway refuses a named client
# certificate once permissions are on); Patroni is identified by the xpam-node account's password
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/O=XPAM HA client" \
  -keyout "$out/client.key" -out "$out/client.csr" 2>/dev/null
printf 'extendedKeyUsage=clientAuth\nkeyUsage=digitalSignature\n' > "$out/client.ext"
openssl x509 -req -in "$out/client.csr" -CA "$out/ca.crt" -CAkey "$out/ca.key" -CAcreateserial -days 3650 \
  -extfile "$out/client.ext" -out "$out/client.crt" 2>/dev/null
rm -f "$out/client.csr" "$out/client.ext"
rm -f "$out/ca.srl"
