#!/usr/bin/env bash
# Change the public address of an existing offline deployment.
#
#   scripts/set-address.sh --host <ip|name> [--port <n>] [--no-restart]
#
# With TLS on (the default, OFFLINE_TLS=1) --port is the public wss port the
# caddy terminator publishes (OFFLINE_TLS_PORT, default 40009) and RELAY_URL
# becomes wss://<host>[:<port>]. With OFFLINE_TLS=0 it is the relay's plain
# HTTP port and RELAY_URL becomes ws://….
#
# The address appears in two places that must move together:
#
#   1. `.env` — OFFLINE_PUBLIC_HOST, the port key, and RELAY_URL, which the
#      relay bakes into NIP-42 challenges, invite links, media URLs and git
#      URLs.
#   2. The `communities` row — a relay resolves every request to a community by
#      host. Booting with a new RELAY_URL would provision a brand-new, empty
#      community and leave every message, channel and member behind under the
#      old host. Renaming the row moves the data with the address.
#
# Renaming is a single UPDATE because every tenant-scoped row hangs off
# `communities.id`, not off the host string.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OFFLINE_DIR="$(cd "$HERE/.." && pwd)"
COMPOSE="$OFFLINE_DIR/compose.yml"
ENV_FILE="$OFFLINE_DIR/.env"

HOST=""
PORT=""
RESTART=1
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:?--host needs a value}"; shift 2 ;;
    --port) PORT="${2:?--port needs a value}"; shift 2 ;;
    --no-restart) RESTART=0; shift ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

say() { printf '\033[1;33m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$ENV_FILE" ] || die "no .env in $OFFLINE_DIR — run install.sh first"

current_host=$(sed -nE 's/^OFFLINE_PUBLIC_HOST=//p' "$ENV_FILE" | head -1)
current_relay=$(sed -nE 's/^RELAY_URL=//p' "$ENV_FILE" | head -1)
TLS=$(sed -nE 's/^OFFLINE_TLS=//p' "$ENV_FILE" | head -1); TLS="${TLS:-1}"
if [ "$TLS" = "1" ]; then
  current_port=$(sed -nE 's/^OFFLINE_TLS_PORT=//p' "$ENV_FILE" | head -1); current_port="${current_port:-40009}"
else
  current_port=$(sed -nE 's/^OFFLINE_HTTP_PORT=//p' "$ENV_FILE" | head -1); current_port="${current_port:-80}"
fi

new_host="${HOST:-$current_host}"
new_port="${PORT:-$current_port}"

case "$new_host" in
  ''|*[!A-Za-z0-9._:-]*) die "invalid host '${new_host}' (letters, digits, dot, dash, colon only)" ;;
esac
case "$new_port" in
  ''|*[!0-9]*) die "invalid port '${new_port}'" ;;
esac

# Relay-side authority: lowercase, default port (443 for wss, 80 for ws)
# omitted — that is the same normalization the relay applies to RELAY_URL and
# to request Host headers.
authority=$(printf '%s' "$new_host" | tr '[:upper:]' '[:lower:]')
if [ "$TLS" = "1" ]; then
  scheme="wss"
  default_port="443"
else
  scheme="ws"
  default_port="80"
fi
if [ "$new_port" = "$default_port" ]; then
  new_relay_url="${scheme}://${authority}"
else
  new_relay_url="${scheme}://${authority}:${new_port}"
fi

old_authority="${current_relay#*://}"
old_authority="${old_authority%%/*}"

if [ "$new_relay_url" = "$current_relay" ]; then
  say "address already ${new_relay_url}; nothing to change"
  exit 0
fi

say "address ${current_relay} -> ${new_relay_url}"

# ── issue/refresh the leaf certificate for the new host when TLS is on ──────
if [ "$TLS" = "1" ]; then
  if [ ! -f "$OFFLINE_DIR/certs/ca.crt" ] || [ ! -f "$OFFLINE_DIR/certs/server.crt" ] \
     || ! openssl x509 -in "$OFFLINE_DIR/certs/server.crt" -noout -checkhost "$new_host" >/dev/null 2>&1; then
    say "issuing/refreshing certificate for ${new_host} (make-ca.sh)"
    "$HERE/make-ca.sh" --host "$new_host" --port "$new_port" --out "$OFFLINE_DIR/certs" >/dev/null
  fi
fi

# ── move the community row ──────────────────────────────────────────────────
say "starting the database"
docker compose -f "$COMPOSE" up -d postgres >/dev/null
for _ in $(seq 1 30); do
  docker compose -f "$COMPOSE" exec -T postgres pg_isready -q -U "${POSTGRES_USER:-buzz}" && break
  sleep 1
done

sql_count=$(printf "SELECT count(*) FROM communities WHERE lower(host) = lower('%s');" "$old_authority")
rows=$(docker compose -f "$COMPOSE" exec -T postgres \
  psql -U "${POSTGRES_USER:-buzz}" -d "${POSTGRES_DB:-buzz}" -tAc "$sql_count" | tr -d '[:space:]')

if [ "${rows:-0}" = "0" ]; then
  say "no community row for ${old_authority} yet (fresh install) — nothing to rebind"
elif [ "${rows:-0}" = "1" ]; then
  say "rebinding community ${old_authority} -> ${new_relay_url#*://}"
  docker compose -f "$COMPOSE" exec -T postgres \
    psql -U "${POSTGRES_USER:-buzz}" -d "${POSTGRES_DB:-buzz}" -v ON_ERROR_STOP=1 -c \
    "UPDATE communities SET host = '${new_relay_url#*://}' WHERE lower(host) = lower('${old_authority}');" >/dev/null
else
  die "${rows} communities match ${old_authority}; this bundle expects one. Change them by hand."
fi

# ── .env ────────────────────────────────────────────────────────────────────
if [ "$TLS" = "1" ]; then
  sed -i.bak -E \
    -e "s|^OFFLINE_PUBLIC_HOST=.*|OFFLINE_PUBLIC_HOST=${new_host}|" \
    -e "s|^OFFLINE_TLS_PORT=.*|OFFLINE_TLS_PORT=${new_port}|" \
    -e "s|^OFFLINE_HTTP_PORT=.*|OFFLINE_HTTP_PORT=80|" \
    -e "s|^OFFLINE_HTTP_BIND=.*|OFFLINE_HTTP_BIND=127.0.0.1|" \
    -e "s|^RELAY_URL=.*|RELAY_URL=${new_relay_url}|" "$ENV_FILE"
else
  sed -i.bak -E \
    -e "s|^OFFLINE_PUBLIC_HOST=.*|OFFLINE_PUBLIC_HOST=${new_host}|" \
    -e "s|^OFFLINE_HTTP_PORT=.*|OFFLINE_HTTP_PORT=${new_port}|" \
    -e "s|^OFFLINE_HTTP_BIND=.*|OFFLINE_HTTP_BIND=0.0.0.0|" \
    -e "s|^RELAY_URL=.*|RELAY_URL=${new_relay_url}|" "$ENV_FILE"
fi
rm -f "${ENV_FILE}.bak"
say "updated $ENV_FILE"

if [ "$RESTART" = "0" ]; then
  say "--no-restart: the relay still runs the old address until it is recreated"
  exit 0
fi

if [ "$TLS" = "1" ]; then
  export COMPOSE_PROFILES=tls
else
  unset COMPOSE_PROFILES
fi

say "recreating the stack"
docker compose -f "$COMPOSE" up -d --force-recreate

say "verifying"
"$HERE/verify.sh"

TLS_NOTE=""
if [ "$TLS" = "1" ]; then
  TLS_NOTE="    (wss:// — desktop 1.0.0 requires wss or https; trust the CA on each PC once:
     copy certs/ca.crt + certs/install-ca.bat to the PC and run install-ca.bat
     as Administrator)"
fi
WEB_URL=$(printf '%s' "$new_relay_url" | sed -e 's|^wss://|https://|' -e 's|^ws://|http://|')
cat <<EOF

Address is now ${new_relay_url}
  web UI / invites: ${WEB_URL}
  clients: point the community URL at ${new_relay_url}
${TLS_NOTE}
EOF
