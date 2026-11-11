#!/usr/bin/env bash
# Install (or upgrade) the Buzz offline relay stack on an air-gapped host.
#
#   scripts/install.sh [options]
#
#   --host <ip|name>   Public host clients use          (default: current value in .env, else 127.0.0.1)
#   --port <n>         Host port mapped to the relay     (default: 80; plain HTTP when TLS is off)
#   --tls-port <n>     Host port published by the TLS terminator, wss:// (default: 40009)
#   --no-tls           Deploy plain HTTP: RELAY_URL=ws://…, relay port published directly
#   --images <dir>     Directory with the release assets (default: ./images)
#   --force            Rewrite .env, including new secrets (destroys the relay identity)
#   --no-start         Load images and write .env, do not start containers
#
# Buzz desktop 1.0.0 only accepts wss://, so TLS is the default: a caddy
# terminator publishes --tls-port and proxies to the relay; the certificate
# comes from scripts/make-ca.sh (private CA, issued here if certs/ is empty).
#
# Everything here works with no network: the tarballs carry the images, the
# compose file has `pull_policy: never`, and secrets are generated locally.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OFFLINE_DIR="$(cd "$HERE/.." && pwd)"
cd "$OFFLINE_DIR"

HOST=""
PORT=""
TLS_PORT=""
TLS=1
IMAGES_DIR="$OFFLINE_DIR/images"
FORCE=0
START=1

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:?--host needs a value}"; shift 2 ;;
    --port) PORT="${2:?--port needs a value}"; shift 2 ;;
    --tls-port) TLS_PORT="${2:?--tls-port needs a value}"; shift 2 ;;
    --no-tls) TLS=0; shift ;;
    --images) IMAGES_DIR="${2:?--images needs a value}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --no-start) START=0; shift ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

say() { printf '\033[1;33m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ── preflight ───────────────────────────────────────────────────────────────
if ! command -v docker >/dev/null; then
  if [ -x "$OFFLINE_DIR/../docker-debs/install.sh" ]; then
    die "docker is not installed — this bundle carries it: sudo ../docker-debs/install.sh"
  fi
  die "docker is not installed — install Docker Engine + compose v2 first (the amd64 bundle ships docker-debs/install.sh for that)"
fi
docker compose version >/dev/null 2>&1 || die "docker compose v2 is required (the bundle's docker-debs/install.sh installs it)"
docker info >/dev/null 2>&1 || die "cannot reach the Docker daemon (is it running? are you in the docker group?)"
command -v openssl >/dev/null || die "openssl is required to generate secrets"

case "$(uname -m)" in
  x86_64|amd64) ARCH=amd64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "unsupported CPU architecture: $(uname -m) (bundle ships amd64 and arm64)" ;;
esac

MANIFEST="$IMAGES_DIR/images-${ARCH}.txt"
[ -f "$MANIFEST" ] || die "missing $MANIFEST — extract the linux-${ARCH} release assets into $IMAGES_DIR (or pass --images DIR)"

# ── checksums ───────────────────────────────────────────────────────────────
if [ -f "$IMAGES_DIR/SHA256SUMS-${ARCH}" ]; then
  say "verifying checksums"
  if command -v sha256sum >/dev/null; then
    ( cd "$IMAGES_DIR" && sha256sum -c "SHA256SUMS-${ARCH}" --quiet )
  else
    ( cd "$IMAGES_DIR" && shasum -a 256 -c "SHA256SUMS-${ARCH}" )
  fi
else
  say "no SHA256SUMS-${ARCH} next to the images — skipping checksum verification"
fi

# ── load images ─────────────────────────────────────────────────────────────
# TLS on: the caddy terminator image is part of the bundle; TLS off: skip it.
SKIP_CADDY=0
[ "$TLS" = "0" ] && SKIP_CADDY=1

RELEASE=""
while IFS=$'\t' read -r name tag expected_id; do
  [ -n "$name" ] || continue
  [ "$SKIP_CADDY" = "1" ] && [ "$name" = "caddy" ] && { say "skipping caddy image (--no-tls)"; continue; }
  RELEASE="${tag##*:}"
  asset="$IMAGES_DIR/${name}-linux-${ARCH}.tar.gz"
  [ -f "$asset" ] || asset="$IMAGES_DIR/${name}-linux-${ARCH}.tar"
  [ -f "$asset" ] || die "missing image archive for ${name}: ${name}-linux-${ARCH}.tar.gz"

  say "loading ${name} from $(basename "$asset")"
  docker load -i "$asset" >/dev/null

  actual_id=$(docker image inspect --format '{{.Id}}' "$tag" 2>/dev/null || true)
  [ -n "$actual_id" ] || die "archive $(basename "$asset") did not provide ${tag}"
  # Image ids are advisory. The archive checksum already proved transport
  # integrity; a daemon may re-key the same image (Docker Desktop/containerd
  # reports the multi-platform index digest where the classic store reports the
  # config digest), so a mismatch is reported, never fatal.
  if [ -n "$expected_id" ] && [ "$actual_id" != "$expected_id" ]; then
    say "note: ${name} image id differs from the bundle manifest (${actual_id##sha256:} vs ${expected_id##sha256:}) — local daemon re-keyed an identical, checksum-verified image"
  fi
done <"$MANIFEST"

[ -n "$RELEASE" ] || die "could not read the bundle release from $MANIFEST"
say "bundle release: ${RELEASE}"

# ── .env ────────────────────────────────────────────────────────────────────
ENV_FILE="$OFFLINE_DIR/.env"
hex() { openssl rand -hex "${1:-32}"; }

if [ "$FORCE" = "0" ] && [ -f "$ENV_FILE" ]; then
  say "keeping existing .env (secrets and relay identity preserved)"
  # Only the image pins and the release pointer move on upgrade.
  sed -i.bak -E "s|^OFFLINE_RELEASE=.*|OFFLINE_RELEASE=${RELEASE}|" "$ENV_FILE"
  for name in relay postgres redis silo mc caddy; do
    upper=$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')
    sed -i.bak -E \
      -e "s|^OFFLINE_IMAGE_${upper}=.*|OFFLINE_IMAGE_${upper}=buzz-offline/${name}:${RELEASE}|" "$ENV_FILE"
  done
  # An upgrade to a TLS bundle turns TLS on unless the operator opted out.
  if [ "$TLS" = "1" ]; then
    sed -i.bak -E "s|^OFFLINE_TLS=.*|OFFLINE_TLS=1|" "$ENV_FILE" 2>/dev/null || true
    grep -q '^OFFLINE_TLS=' "$ENV_FILE" || echo "OFFLINE_TLS=1" >>"$ENV_FILE"
  fi

  # Address change: --host/--port go through set-address.sh, which rebinds the
  # community row (data follows the address) before RELAY_URL moves.
  if [ -n "$HOST" ] || [ -n "$PORT" ]; then
    addr_args=()
    [ -n "$HOST" ] && addr_args+=(--host "$HOST")
    [ -n "$PORT" ] && addr_args+=(--port "$PORT")
    "$OFFLINE_DIR/scripts/set-address.sh" --no-restart "${addr_args[@]}"
  fi
else
  [ "$FORCE" = "1" ] && [ -f "$ENV_FILE" ] && say "--force: regenerating .env (relay identity will change)"

  if [ -z "$HOST" ]; then
    HOST=$(sed -nE 's/^OFFLINE_PUBLIC_HOST=//p' "$ENV_FILE" 2>/dev/null | head -1 || true)
  fi
  HOST="${HOST:-127.0.0.1}"
  if [ -z "$PORT" ]; then
    PORT=$(sed -nE 's/^OFFLINE_HTTP_PORT=//p' "$ENV_FILE" 2>/dev/null | head -1 || true)
  fi
  PORT="${PORT:-80}"
  if [ -z "$TLS_PORT" ]; then
    TLS_PORT=$(sed -nE 's/^OFFLINE_TLS_PORT=//p' "$ENV_FILE" 2>/dev/null | head -1 || true)
  fi
  TLS_PORT="${TLS_PORT:-40009}"

  # RELAY_URL scheme follows the TLS switch. Port 443/80 are omitted from the
  # URL (default ports), matching the relay's own authority normalization.
  if [ "$TLS" = "1" ]; then
    if [ "$TLS_PORT" = "443" ]; then
      RELAY_URL="wss://${HOST}"
    else
      RELAY_URL="wss://${HOST}:${TLS_PORT}"
    fi
    HTTP_BIND="127.0.0.1"
  else
    if [ "$PORT" = "80" ]; then
      RELAY_URL="ws://${HOST}"
    else
      RELAY_URL="ws://${HOST}:${PORT}"
    fi
    HTTP_BIND="0.0.0.0"
  fi

  say "writing $ENV_FILE (host ${HOST}, tls=${TLS}, tls_port=${TLS_PORT}, http_port=${PORT})"
  umask 077
  cat >"$ENV_FILE" <<EOF
# Generated by offline/scripts/install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# Secrets below are the deployment identity: back this file up and keep it
# stable across upgrades. Use --force only to start over.
OFFLINE_RELEASE=${RELEASE}
OFFLINE_PUBLIC_HOST=${HOST}
OFFLINE_TLS=${TLS}
OFFLINE_TLS_PORT=${TLS_PORT}
OFFLINE_HTTP_BIND=${HTTP_BIND}
OFFLINE_HTTP_PORT=${PORT}
OFFLINE_HEALTH_PORT=18080
RELAY_URL=${RELAY_URL}

OFFLINE_IMAGE_RELAY=buzz-offline/relay:${RELEASE}
OFFLINE_IMAGE_POSTGRES=buzz-offline/postgres:${RELEASE}
OFFLINE_IMAGE_REDIS=buzz-offline/redis:${RELEASE}
OFFLINE_IMAGE_SILO=buzz-offline/silo:${RELEASE}
OFFLINE_IMAGE_MC=buzz-offline/mc:${RELEASE}
OFFLINE_IMAGE_CADDY=buzz-offline/caddy:${RELEASE}

BUZZ_RELAY_PRIVATE_KEY=$(hex 32)
BUZZ_GIT_HOOK_HMAC_SECRET=$(hex 32)

POSTGRES_DB=buzz
POSTGRES_USER=buzz
POSTGRES_PASSWORD=$(hex 24)
REDIS_PASSWORD=$(hex 24)
BUZZ_S3_ACCESS_KEY=buzz
BUZZ_S3_SECRET_KEY=$(hex 24)
BUZZ_S3_BUCKET=buzz-media
EOF
  umask 022
fi

# ── TLS certificate (only when TLS is on) ───────────────────────────────────
ENV_TLS="$TLS"
if [ "$FORCE" = "0" ] && [ -f "$ENV_FILE" ]; then
  ENV_TLS=$(sed -nE 's/^OFFLINE_TLS=//p' "$ENV_FILE" | head -1); ENV_TLS="${ENV_TLS:-1}"
fi
COMPOSE_PROFILES=""
if [ "$ENV_TLS" = "1" ]; then
  COMPOSE_PROFILES="tls"
  export COMPOSE_PROFILES
  if [ ! -f "$OFFLINE_DIR/certs/server.crt" ] || [ ! -f "$OFFLINE_DIR/certs/ca.crt" ]; then
    PUB_HOST=$(sed -nE 's/^OFFLINE_PUBLIC_HOST=//p' "$ENV_FILE" | head -1)
    PUB_HOST="${PUB_HOST:-${HOST:-127.0.0.1}}"
    PUB_TLS_PORT=$(sed -nE 's/^OFFLINE_TLS_PORT=//p' "$ENV_FILE" | head -1); PUB_TLS_PORT="${PUB_TLS_PORT:-40009}"
    say "no certificate in $OFFLINE_DIR/certs — issuing one for ${PUB_HOST} (make-ca.sh)"
    "$OFFLINE_DIR/scripts/make-ca.sh" --host "$PUB_HOST" --port "$PUB_TLS_PORT" --out "$OFFLINE_DIR/certs" >/dev/null
  fi
  [ -f "$OFFLINE_DIR/certs/server.crt" ] || die "certs/server.crt missing — run: scripts/make-ca.sh --host <host> --port <tls-port>"
else
  unset COMPOSE_PROFILES
fi

# ── start ───────────────────────────────────────────────────────────────────
if [ "$START" = "0" ]; then
  say "--no-start: not starting containers"
  exit 0
fi

say "starting the stack (profiles: ${COMPOSE_PROFILES:-<none>})"
docker compose -f "$OFFLINE_DIR/compose.yml" up -d --remove-orphans

say "waiting for /_readiness"
ready=0
for _ in $(seq 1 60); do
  if docker compose -f "$OFFLINE_DIR/compose.yml" exec -T relay bash -ec \
      'exec 3<>/dev/tcp/127.0.0.1/8080; printf "GET /_readiness HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n" >&3; grep -q "200 OK" <&3' \
      >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
[ "$ready" = "1" ] || die "relay did not become ready — see: docker compose -f $OFFLINE_DIR/compose.yml logs relay"

say "running verification"
verify_rc=0
"$OFFLINE_DIR/scripts/verify.sh" || verify_rc=$?

RELAY_URL_NOW=$(sed -nE 's/^RELAY_URL=//p' "$ENV_FILE" | head -1)
WEB_URL=$(printf '%s' "$RELAY_URL_NOW" | sed -e 's|^wss://|https://|' -e 's|^ws://|http://|')
TLS_PORT=$(sed -nE 's/^OFFLINE_TLS_PORT=//p' "$ENV_FILE" | head -1); TLS_PORT="${TLS_PORT:-40009}"
PUBLIC_HOST=$(sed -nE 's/^OFFLINE_PUBLIC_HOST=//p' "$ENV_FILE" | head -1)
TLS_URL="wss://${PUBLIC_HOST}:${TLS_PORT}"

cat <<EOF

$(printf '\033[1;32mready\033[0m')  Buzz is up.
  relay URL:      ${RELAY_URL_NOW}
  web / invites:  ${WEB_URL}
  health (local): http://127.0.0.1:$(sed -nE 's/^OFFLINE_HEALTH_PORT=//p' "$ENV_FILE" | head -1)/_readiness

In the Buzz desktop app choose "Add community" and paste ${RELAY_URL_NOW}
(desktop 1.0.0 accepts wss:// or https:// only — ws:// is rejected by the app).

First time on each Windows client PC, run once as Administrator to trust this
relay's private CA:   copy offline/certs/ca.crt + offline/certs/install-ca.bat
to the PC and right-click install-ca.bat -> "Run as administrator".

Offline guarantee: containers already have no internet route, but if this host
does have one, close it with: sudo ${OFFLINE_DIR}/scripts/lockdown.sh apply

Logs:     docker compose -f ${OFFLINE_DIR}/compose.yml logs -f relay
Back up:  ${OFFLINE_DIR}/scripts/backup.sh
Upgrade:  sudo ${OFFLINE_DIR}/scripts/upgrade.sh --bundle <new-release>.tar.gz
          (one step: extracts, keeps .env/data, loads new images, verifies)
EOF

exit "$verify_rc"
