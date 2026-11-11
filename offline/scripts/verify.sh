#!/usr/bin/env bash
# Prove a running offline stack actually serves what clients need.
#
#   scripts/verify.sh
#
# Checks run inside the relay container so the target host needs no curl,
# python or websocket tooling of its own:
#
#   1. every service is running / healthy (caddy too when OFFLINE_TLS=1)
#   2. no container can reach the internet, while the published port still works
#   3. /_liveness and /_readiness answer 200
#   4. the relay document is served at / and the web bundle at /invite/<code>
#   5. a WebSocket upgrade on the app port returns 101
#   5b. the published public port answers (TLS ServerHello when OFFLINE_TLS=1)
#   5c. the server certificate chains to certs/ca.crt and its SAN matches the host
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
tls="0"
pub_host="127.0.0.1"
pub_port="80"
tls_port="40009"
if [ -f "$ENV_FILE" ]; then
  tls=$(sed -nE 's/^OFFLINE_TLS=//p' "$ENV_FILE" | head -1); tls="${tls:-1}"
  pub_host=$(sed -nE 's/^OFFLINE_PUBLIC_HOST=//p' "$ENV_FILE" | head -1); pub_host="${pub_host:-127.0.0.1}"
  pub_port=$(sed -nE 's/^OFFLINE_HTTP_PORT=//p' "$ENV_FILE" | head -1); pub_port="${pub_port:-80}"
  tls_port=$(sed -nE 's/^OFFLINE_TLS_PORT=//p' "$ENV_FILE" | head -1); tls_port="${tls_port:-40009}"
fi
# compose profiles must match what install.sh/set-address.sh started.
if [ "$tls" = "1" ]; then export COMPOSE_PROFILES=tls; else unset COMPOSE_PROFILES; fi

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
if [ "$tls" = "1" ]; then
  if docker compose -f "$COMPOSE" ps --status running --services 2>/dev/null | grep -qx "caddy"; then
    ok "service caddy (TLS terminator) running"
  else
    bad "service caddy not running (docker compose -f $COMPOSE logs caddy)"
  fi
fi

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

# 5b ── ingress through the published port, from outside the container ────────
if [ "$tls" = "1" ]; then
  # TLS on: the public port is the caddy terminator's. A TLS ClientHello that
  # gets a ServerHello back proves the listener and the certificate load;
  # chain/SAN validation against our own CA is check 5c below.
  if (exec 3<>"/dev/tcp/${pub_host}/${tls_port}" 2>/dev/null; \
      printf '\x16\x03\x01\x00\x2e\x01\x00\x00\x2a\x03\x03' >&3 2>/dev/null; \
      IFS= read -r -t 5 -n 5 resp <&3; \
      case "$resp" in $'\x16\x03'*) exit 0 ;; *) exit 1 ;; esac) 2>/dev/null; then
    ok "published TLS port ${pub_host}:${tls_port} answers (TLS ServerHello)"
  else
    bad "published TLS port ${pub_host}:${tls_port} is not answering (firewall? wrong port?)"
  fi
else
  if (exec 3<>"/dev/tcp/${pub_host}/${pub_port}" 2>/dev/null; \
      printf 'GET / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n' "$authority" >&3; \
      IFS= read -r -t 5 line <&3; \
      case "$line" in *" 200 "*) exit 0 ;; *) exit 1 ;; esac) 2>/dev/null; then
    ok "published port ${pub_host}:${pub_port} answers HTTP 200"
  else
    bad "published port ${pub_host}:${pub_port} is not answering (firewall? wrong port?)"
  fi
fi

# 5c ── TLS path: certificate chains to the bundle CA and matches the host SAN.
if [ "$tls" = "1" ]; then
  if command -v openssl >/dev/null 2>&1 && [ -f "$OFFLINE_DIR/certs/ca.crt" ]; then
    if openssl verify -CAfile "$OFFLINE_DIR/certs/ca.crt" "$OFFLINE_DIR/certs/server.crt" >/dev/null 2>&1; then
      ok "server certificate chains to certs/ca.crt"
    else
      bad "certs/server.crt does not verify against certs/ca.crt"
    fi
    if openssl x509 -in "$OFFLINE_DIR/certs/server.crt" -noout -checkhost "$pub_host" >/dev/null 2>&1; then
      ok "certificate SAN matches ${pub_host}"
    else
      bad "certificate SAN does not match ${pub_host} — re-issue: scripts/make-ca.sh --host ${pub_host} --port ${tls_port}"
    fi
  else
    echo "  note: openssl or certs/ca.crt missing — skipping certificate checks"
  fi
fi

# ── how clients reach it ────────────────────────────────────────────────────
if [ -f "$ENV_FILE" ]; then
  host=$(sed -nE 's/^OFFLINE_PUBLIC_HOST=//p' "$ENV_FILE" | head -1)
  relay_url=$(sed -nE 's/^RELAY_URL=//p' "$ENV_FILE" | head -1)
  web_url=$(printf '%s' "$relay_url" | sed -e 's|^wss://|https://|' -e 's|^ws://|http://|')
  echo
  echo "  relay (app): ${relay_url}"
  echo "  web/invite:  ${web_url}"
  echo "  health:      http://127.0.0.1:$(sed -nE 's/^OFFLINE_HEALTH_PORT=//p' "$ENV_FILE" | head -1)/_readiness"
  if [ "$tls" = "1" ]; then
    echo "  CA cert for clients: ${OFFLINE_DIR}/certs/ca.crt  (+ certs/install-ca.bat on Windows)"
  fi
fi

echo
if [ "$fails" -eq 0 ]; then
  printf '\033[1;32mverification passed\033[0m\n'
else
  printf '\033[1;31mverification failed (%d check(s))\033[0m\n' "$fails"
  exit 1
fi
