#!/usr/bin/env bash
# Install Docker Engine + Compose from the packages shipped in this bundle.
#
#   sudo ./install.sh            # Ubuntu 24.04 (amd64), no internet
#
# The archive's docker-debs/ directory carries docker-ce, docker-ce-cli,
# containerd.io, docker-buildx-plugin and docker-compose-plugin, plus the
# iptables/nftables packages a minimal Ubuntu 24.04 lacks (dockerd needs them
# for its bridge and for publishing a port). Nothing is downloaded here.
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

# Everything in this folder that the host is missing gets installed: the docker
# packages themselves (always, they are upgrades) plus the iptables/nftables
# closure a minimal Ubuntu 24.04 lacks — dockerd cannot build its bridge or
# publish a port without them. No package list is kept here on purpose, so the
# set cannot drift from what CI actually shipped.
#
# The docker packages go last: they depend on the toolchain unpacked before
# them, and dpkg configures in the order it is handed the files.
installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
docker_pkgs=" docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin "
deps=()
docker=()
for f in "$HERE"/*.deb; do
  [ -f "$f" ] || continue
  pkg=$(dpkg-deb -f "$f" Package 2>/dev/null || true)
  [ -n "$pkg" ] || continue
  case "$docker_pkgs" in
    *" $pkg "*) docker+=("$f") ;;
    *) installed "$pkg" || deps+=("$f") ;;
  esac
done
debs=("${deps[@]}" "${docker[@]}")
[ "${#debs[@]}" -gt 0 ] || die "no .deb packages found in $HERE"

say "installing ${#debs[@]} packages"
set +e
out=$(dpkg -i "${debs[@]}" 2>&1)
rc=$?
set -e
if [ "$rc" != 0 ]; then
  printf '%s\n' "$out" | tail -20
  # A package whose dependency only appeared later in the batch is unpacked but
  # unconfigured; a second pass converges instead of failing the install.
  say "re-running configuration for packages that needed a later dependency"
  dpkg --configure -a >/dev/null 2>&1 || true
fi

audit=$(dpkg --audit 2>&1 || true)
if [ -n "$audit" ]; then
  printf '%s\n' "$audit" >&2
  missing=$(printf '%s\n' "$out$audit" | sed -nE 's/.*depends on ([^;]+);.*/\1/p' | sed 's/ (.*//' | sort -u | tr '\n' ' ')
  cat >&2 <<EOF

error: some packages are still unconfigured.
missing/unsatisfied dependencies: ${missing:-unknown}

On a machine with internet and the same Ubuntu 24.04 (amd64), run:
    apt-get download ${missing:-iptables nftables}
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
