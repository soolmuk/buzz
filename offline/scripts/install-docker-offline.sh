#!/usr/bin/env bash
# Install Docker Engine + Compose from the packages shipped in this bundle.
#
#   sudo ./install.sh            # Ubuntu 24.04 (amd64), no internet
#
# The archive's docker-debs/ directory carries docker-ce, docker-ce-cli,
# containerd.io, docker-buildx-plugin and docker-compose-plugin. Nothing is
# downloaded here.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say() { printf '\033[1;33m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "run as root (sudo $0)"

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  say "docker + compose already installed: $(docker --version)"
  exit 0
fi

[ "$(uname -m)" = "x86_64" ] || die "these packages are amd64 only (this host is $(uname -m))"

# Dependency order: the CLI and runtime first, the daemon last.
order=(containerd.io docker-ce-cli docker-buildx-plugin docker-compose-plugin docker-ce)
debs=()
for pkg in "${order[@]}"; do
  for f in "$HERE/${pkg}"_*.deb; do
    [ -f "$f" ] && debs+=("$f")
  done
done
[ "${#debs[@]}" -gt 0 ] || die "no .deb packages found in $HERE"

say "installing ${#debs[@]} packages"
if ! out=$(dpkg -i "${debs[@]}" 2>&1); then
  printf '%s\n' "$out" | tail -20
  missing=$(printf '%s\n' "$out" | sed -nE 's/.*Depends: ([^;]+).*/\1/p' | tr ',' '\n' | sed 's/(.*)//;s/^ *//' | sort -u | tr '\n' ' ')
  cat >&2 <<EOF

error: dpkg could not finish the install.
missing/unsatisfied dependencies: ${missing:-unknown}

On a machine with internet and the same Ubuntu 24.04 (amd64), run:
    apt-get download iptables nftables ${missing}
copy the resulting .deb files into this folder and run this script again.
EOF
  exit 1
fi

say "enabling the daemon"
systemctl enable --now docker >/dev/null 2>&1 || say "note: could not enable docker via systemd; start it manually (dockerd &)"

if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  usermod -aG docker "$SUDO_USER" || true
  say "added $SUDO_USER to the docker group (log out and back in for it to apply)"
fi

say "versions"
docker --version
docker compose version
