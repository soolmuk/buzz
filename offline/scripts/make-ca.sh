#!/usr/bin/env bash
# Issue a private-CA certificate for the offline Buzz relay, so desktop 1.0.0
# (which only accepts wss://) can connect over TLS without a public domain.
#
#   scripts/make-ca.sh --host <ip|name> [--port <n>] [--out <dir>]
#
# Produces in <out> (default: ../certs, the directory compose mounts into the
# TLS terminator as /certs):
#   ca.crt / ca.key        the private CA (install ca.crt into each client's OS root store)
#   server.crt / server.key  leaf certificate with SAN = <host> (IP or DNS)
#
# Everything is local: openssl only, no network. The leaf is valid 825 days
# (Apple's ceiling for TLS server certs) and the CA 10 years.
#
# After running this, ship ca.crt + certs/install-ca.bat to every Windows
# client and run install-ca.bat once as Administrator; clients then use
# wss://<host>[:<port>].
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OFFLINE_DIR="$(cd "$HERE/.." && pwd)"

HOST=""
PORT=""
OUT="$OFFLINE_DIR/certs"
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:?--host needs a value}"; shift 2 ;;
    --port) PORT="${2:?--port needs a value}"; shift 2 ;;
    --out) OUT="${2:?--out needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

say() { printf '\033[1;33m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v openssl >/dev/null || die "openssl is required"
[ -n "$HOST" ] || die "--host <ip|name> is required (the exact address clients will type)"

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
umask 077

# SAN: IP addresses need IP:, names need DNS:.
if printf '%s' "$HOST" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
  SAN="IP:${HOST}"
else
  SAN="DNS:${HOST}"
fi
say "SAN will be ${SAN} (port ${PORT:-443} is not part of the cert)"

# --- CA ---------------------------------------------------------------------
if [ ! -f "$OUT/ca.key" ]; then
  say "creating private CA (10y)"
  openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
    -keyout "$OUT/ca.key" -out "$OUT/ca.crt" \
    -subj "/CN=Buzz Offline Relay CA/O=Buzz Offline" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" >/dev/null 2>&1
else
  say "reusing existing $OUT/ca.crt"
fi

# --- leaf -------------------------------------------------------------------
say "issuing server certificate for ${HOST} (825d)"
openssl req -newkey rsa:2048 -sha256 -nodes \
  -keyout "$OUT/server.key" -out "$OUT/server.csr" \
  -subj "/CN=${HOST}" >/dev/null 2>&1

cat >"$OUT/server.ext" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=${SAN}
EOF

openssl x509 -req -sha256 -days 825 \
  -in "$OUT/server.csr" \
  -CA "$OUT/ca.crt" -CAkey "$OUT/ca.key" -CAcreateserial \
  -out "$OUT/server.crt" -extfile "$OUT/server.ext" >/dev/null 2>&1
rm -f "$OUT/server.csr" "$OUT/server.ext" "$OUT/ca.srl"

chmod 600 "$OUT"/*.key
say "verifying chain"
openssl verify -CAfile "$OUT/ca.crt" "$OUT/server.crt"

cat <<EOF

\033[1;32mcertificates ready\033[0m in $OUT
  server.crt + server.key -> already where compose mounts them (offline/certs,
                             mounted read-only into the caddy terminator)
  ca.crt + certs/install-ca.bat -> copy to each WINDOWS client and run
                             install-ca.bat ONCE as Administrator (one click)

Then set the public address with TLS:
  ./scripts/set-address.sh --host ${HOST} --port ${PORT:-40009}   # RELAY_URL becomes wss://…

Clients then use:  wss://${HOST}${PORT:+:$PORT}
(Desktop 1.0.0 only accepts wss:// or https:// — ws:// is rejected by the app.)
EOF
