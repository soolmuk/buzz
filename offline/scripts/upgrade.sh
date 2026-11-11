#!/usr/bin/env bash
# Upgrade an existing offline Buzz relay deployment to a NEW release bundle,
# in one step, with no internet on the target host.
#
#   scripts/upgrade.sh --bundle <path-to buzz-offline-<arch>-<release>.tar.gz> [--release <tag>]
#
# What it does (all offline):
#   1. verifies the bundle's sha256 (next to the archive, or --release's asset)
#   2. extracts it next to the current offline/ directory
#   3. copies the existing .env AND certs/ (private CA) into the new tree, then
#      re-runs the NEW install.sh WITHOUT --force: the existing .env wins, so
#      relay identity, secrets, data and the CA all survive and only the image
#      tags swap to the new release
#   4. runs the NEW verify.sh
#
# The bundle must come from the same architecture (amd64/arm64) as the host.
# Run as root when the install lives under a root-owned directory (typical).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OFFLINE_DIR="$(cd "$HERE/.." && pwd)"

BUNDLE=""
RELEASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --bundle) BUNDLE="${2:?--bundle needs a value}"; shift 2 ;;
    --release) RELEASE="${2:?--release needs a value}"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

say() { printf '\033[1;33m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ -n "$BUNDLE" ] || die "--bundle <path> is required"
[ -f "$BUNDLE" ] || die "bundle not found: $BUNDLE"
[ -f "$OFFLINE_DIR/.env" ] || die "no $OFFLINE_DIR/.env — is this an installed deployment? (run install.sh first)"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else openssl dgst -sha256 -r "$1" | cut -d' ' -f1
  fi
}

BUNDLE="$(cd "$(dirname "$BUNDLE")" && pwd)/$(basename "$BUNDLE")"
NAME="$(basename "$BUNDLE" .tar.gz)"          # buzz-offline-<arch>-<release>
ARCH_PART="${NAME#buzz-offline-}"; ARCH_PART="${ARCH_PART%%-*}"
HOST_ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')"
[ "$ARCH_PART" = "$HOST_ARCH" ] || die "bundle is $ARCH_PART but this host is $HOST_ARCH"

# 1 — checksum (sidecar .sha256 shipped with the release)
if [ -f "$BUNDLE.sha256" ]; then
  say "verifying sha256"
  ( cd "$(dirname "$BUNDLE")" && sha256sum -c "$(basename "$BUNDLE").sha256" --quiet ) \
    || ( cd "$(dirname "$BUNDLE")" && shasum -a 256 -c "$(basename "$BUNDLE").sha256" )
else
  say "note: no $BUNDLE.sha256 sidecar — skipping checksum (sha256: $(sha256_of "$BUNDLE"))"
fi

# 2 — extract next to the current install (keep the old offline/ intact)
PARENT="$(dirname "$OFFLINE_DIR")"
say "extracting $NAME into $PARENT"
tar -xzf "$BUNDLE" -C "$PARENT"
NEW_DIR="$PARENT/$NAME"
[ -f "$NEW_DIR/offline/scripts/install.sh" ] || die "archive did not contain $NAME/offline/scripts/install.sh"

# 3 — upgrade in place: new install.sh, no --force, same .env copied over
say "upgrading $OFFLINE_DIR -> $NAME (keeping .env: identity and data survive)"
cp "$OFFLINE_DIR/.env" "$NEW_DIR/offline/.env"
# Carry the TLS material over too: the CA (ca.crt/ca.key) and leaf must survive
# an upgrade or every client loses trust and the terminator stops.
if [ -d "$OFFLINE_DIR/certs" ]; then
  say "carrying over certs/ (private CA + leaf)"
  mkdir -p "$NEW_DIR/offline/certs"
  cp -a "$OFFLINE_DIR/certs/." "$NEW_DIR/offline/certs/"
fi
cd "$NEW_DIR/offline"
./scripts/install.sh        # no --force, no --host/--port: existing .env values win

# 4 — verify
say "verifying"
./scripts/verify.sh

HEALTH_PORT="$(sed -nE 's/^OFFLINE_HEALTH_PORT=//p' .env | head -1)"
HEALTH_PORT="${HEALTH_PORT:-18080}"
cat <<EOF

\033[1;32mupgrade complete\033[0m — running release ${NAME#buzz-offline-*-}
  directory: $NEW_DIR/offline
  relay:     $(sed -nE 's/^RELAY_URL=//p' .env | head -1)
  health:    http://127.0.0.1:${HEALTH_PORT}/_readiness

Old directory kept at: $OFFLINE_DIR (delete when you are satisfied)
Next upgrade: drop the newer bundle anywhere and run
  sudo $NEW_DIR/offline/scripts/upgrade.sh --bundle <new-bundle.tar.gz>
EOF
