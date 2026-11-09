#!/usr/bin/env bash
# Prove a running offline stack actually serves what clients need.
#
#   scripts/verify.sh
#
# Checks run inside the relay container so the target host needs no curl,
# python or websocket tooling of its own:
#
#   1. every service is running / healthy
#   2. no container can reach the internet, while the published port still works
#   3. /_liveness and /_readiness answer 200
#   4. the relay document is served at / and the web bundle at /invite/<code>
#   5. a WebSocket upgrade on the app port returns 101
#
# The deeper NIP-42 auth + publish + read round trip is
# scripts/verify-nip42.py (needs python3 with the `websockets` package; run it
# from a workstation, not necessarily from the server).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OFFLINE_DIR="$(cd "$HERE/.." && pwd)"
COMPOSE="$OFFLINE_DIR/compose.yml"
ENV_FILE="$OFFLINE_DIR/.env"

fails=0
ok() { printf '  \033[1;32mok\033[0m   %s\n' "$*"; }
bad() { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; fails=$((fails + 1)); }

# The relay resolves a request to a community by Host header, and the community
# host comes from RELAY_URL. Probe with that exact authority or a non-80 deploy
# answers "no community is configured for this host".
relay_url=""
[ -f "$ENV_FILE" ] && relay_url=$(sed -nE 's/^RELAY_URL=//p' "$ENV_FILE" | head -1)
authority="${relay_url#*://}"
authority="${authority%%/*}"
authority="${authority:-127.0.0.1}"

in_relay() {
  docker compose -f "$COMPOSE" exec -T -e VERIFY_AUTHORITY="$authority" relay bash -ec "$1" >/dev/null 2>&1
}

echo "Buzz offline verification"

# A freshly (re)created relay takes a few seconds before its health listener
# answers; wait instead of reporting a false failure.
for _ in $(seq 1 30); do
  if in_relay 'exec 3<>/dev/tcp/127.0.0.1/8080; printf "GET /_readiness HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n" >&3; grep -q "200 OK" <&3'; then
    break
  fi
  sleep 2
done

# 1 ── services running
for svc in relay postgres redis silo; do
  if docker compose -f "$COMPOSE" ps --status running --services 2>/dev/null | grep -qx "$svc"; then
    ok "service $svc running"
  else
    bad "service $svc not running (docker compose -f $COMPOSE logs $svc)"
  fi
done

# 1b ── egress lockdown: no container may reach the internet.
# The relay's only outward-facing network has NAT disabled, so its outbound
# packets are unroutable while the DNAT'd published port still accepts inbound
# connections. Assert both halves: blocked egress, working ingress.
for svc in relay postgres redis silo; do
  if docker compose -f "$COMPOSE" exec -T "$svc" sh -c '
        if command -v nc >/dev/null 2>&1; then nc -z -w 3 1.1.1.1 443;
        else curl -sS --max-time 3 -o /dev/null http://1.1.1.1; fi' >/dev/null 2>&1; then
    bad "$svc reached 1.1.1.1:443 — the host has a route out; run 'sudo scripts/lockdown.sh apply' (on an air-gapped host this check passes on its own)"
  else
    ok "$svc has no outbound internet"
  fi
done

# 2 ── health routers
if in_relay 'exec 3<>/dev/tcp/127.0.0.1/8080; printf "GET /_liveness HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n" >&3; grep -q "200 OK" <&3'; then
  ok "/_liveness 200"
else
  bad "/_liveness did not answer 200"
fi

if in_relay 'exec 3<>/dev/tcp/127.0.0.1/8080; printf "GET /_readiness HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n" >&3; grep -q "200 OK" <&3'; then
  ok "/_readiness 200"
else
  bad "/_readiness did not answer 200 (database or object store not reachable)"
fi

# 3 ── relay surface at / and the web bundle at /invite/<code>
# `/` is the relay's NIP-11 document (a plain HTTP GET), not the SPA: the SPA is
# served on invite landing paths, which is what the browser opens from a link.
if in_relay 'curl -fsS -H "Host: $VERIFY_AUTHORITY" http://127.0.0.1:3000/ | grep -q "github.com/block/buzz"'; then
  ok "NIP-11 relay document at /"
else
  bad "no NIP-11 relay document at /"
fi

if in_relay 'curl -fsS -H "Host: $VERIFY_AUTHORITY" -H "Accept: text/html" http://127.0.0.1:3000/invite/smoke | grep -q "<div id=\"root\">"'; then
  ok "web bundle served at /invite/<code>"
else
  bad "web bundle missing at /invite/<code> (is this the buzz relay image with the web bundle?)"
fi

# 4 ── websocket upgrade on the app port
if in_relay 'exec 3<>/dev/tcp/127.0.0.1/3000; printf "GET / HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n" "$VERIFY_AUTHORITY" >&3; IFS= read -r -t 5 status <&3; case "$status" in *" 101 "*) exit 0 ;; *) echo "$status"; exit 1 ;; esac'; then
  ok "websocket upgrade 101 on :3000"
else
  bad "websocket upgrade did not return 101"
fi

# 5b ── ingress through the published port, from outside the container
pub_host=""
pub_port=""
if [ -f "$ENV_FILE" ]; then
  pub_host=$(sed -nE 's/^OFFLINE_PUBLIC_HOST=//p' "$ENV_FILE" | head -1)
  pub_port=$(sed -nE 's/^OFFLINE_HTTP_PORT=//p' "$ENV_FILE" | head -1)
fi
pub_port="${pub_port:-80}"
pub_host="${pub_host:-127.0.0.1}"
if (exec 3<>"/dev/tcp/${pub_host}/${pub_port}" 2>/dev/null; \
    printf 'GET / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n' "$authority" >&3; \
    IFS= read -r -t 5 line <&3; \
    case "$line" in *" 200 "*) exit 0 ;; *) exit 1 ;; esac) 2>/dev/null; then
  ok "published port ${pub_host}:${pub_port} answers HTTP 200"
else
  bad "published port ${pub_host}:${pub_port} is not answering (firewall? wrong port?)"
fi

# ── how clients reach it
if [ -f "$ENV_FILE" ]; then
  http_port=$(sed -nE 's/^OFFLINE_HTTP_PORT=//p' "$ENV_FILE" | head -1)
  host=$(sed -nE 's/^OFFLINE_PUBLIC_HOST=//p' "$ENV_FILE" | head -1)
  relay_url=$(sed -nE 's/^RELAY_URL=//p' "$ENV_FILE" | head -1)
  echo
  if [ "${http_port:-80}" = "80" ]; then
    echo "  open:  http://${host}"
  else
    echo "  open:  http://${host}:${http_port}"
  fi
  echo "  relay: ${relay_url}"
  echo "  health: http://127.0.0.1:$(sed -nE 's/^OFFLINE_HEALTH_PORT=//p' "$ENV_FILE" | head -1)/_readiness"
fi

echo
if [ "$fails" -eq 0 ]; then
  printf '\033[1;32mverification passed\033[0m\n'
else
  printf '\033[1;31mverification failed (%d check(s))\033[0m\n' "$fails"
  exit 1
fi
