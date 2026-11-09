#!/usr/bin/env bash
# Block internet egress for this stack's containers (Linux host, root).
#
#   sudo scripts/lockdown.sh apply    install the rules (and persist them)
#   scripts/lockdown.sh status        show current state
#   sudo scripts/lockdown.sh remove   drop the rules
#
# Why this exists: a published port requires a non-internal Docker network, so
# the relay always has *some* interface with a default route. The compose file
# already sets `enable_ip_masquerade=false` on that network (its packets carry
# an unroutable 10.42.250.0/24 source), and the data plane is `internal`. That
# is defense in depth, not a guarantee: only the host firewall can guarantee
# nothing leaves the box.
#
# The rules live in DOCKER-USER, which Docker evaluates before its own chains,
# so they survive `docker compose up/down` and never collide with Docker's rules:
#
#   - accept replies on established connections, so inbound traffic to the
#     published port still works
#   - drop everything else originating from the stack's outward-facing subnet
#
# On an air-gapped host the rules are belt-and-braces: the probe in verify.sh
# already fails for lack of a route.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OFFLINE_DIR="$(cd "$HERE/.." && pwd)"
COMPOSE="$OFFLINE_DIR/compose.yml"
PROJECT="${COMPOSE_PROJECT:-buzz-offline}"
EDGE_NET="${PROJECT}_edge"
UNIT=/etc/systemd/system/buzz-offline-egress.service

say() { printf '\033[1;33m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Linux" ] || die "host firewall rules only exist on Linux; on Docker Desktop the daemon runs in a VM"

subnet() {
  docker network inspect "$EDGE_NET" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null
}

need_root() {
  [ "$(id -u)" = "0" ] || die "run as root (sudo $0 $1)"
}

apply() {
  need_root apply
  command -v iptables >/dev/null || die "iptables not found (install iptables or nftables with the iptables wrapper)"
  local net
  net=$(subnet)
  [ -n "$net" ] || die "network $EDGE_NET not found — start the stack once first (scripts/install.sh)"

  # Idempotent: clear our two rules if a previous apply left them.
  remove_rules "$net" >/dev/null 2>&1 || true

  iptables -w -I DOCKER-USER 1 -s "$net" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -w -I DOCKER-USER 2 -s "$net" -j DROP
  say "egress blocked for ${net} (inbound published ports still work)"

  if command -v systemctl >/dev/null; then
    cat >"$UNIT" <<EOF
[Unit]
Description=Block internet egress for the Buzz offline stack
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${HERE}/lockdown.sh apply

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now buzz-offline-egress.service >/dev/null 2>&1 || true
    say "persisted as $UNIT (survives reboot)"
  fi
}

remove_rules() {
  local net="$1"
  while iptables -w -C DOCKER-USER -s "$net" -j DROP 2>/dev/null; do
    iptables -w -D DOCKER-USER -s "$net" -j DROP
  done
  while iptables -w -C DOCKER-USER -s "$net" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; do
    iptables -w -D DOCKER-USER -s "$net" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  done
}

remove() {
  need_root remove
  local net
  net=$(subnet)
  [ -n "$net" ] || die "network $EDGE_NET not found"
  remove_rules "$net"
  if command -v systemctl >/dev/null; then
    systemctl disable --now buzz-offline-egress.service >/dev/null 2>&1 || true
    rm -f "$UNIT"
    systemctl daemon-reload || true
  fi
  say "egress rules removed"
}

status() {
  local net
  net=$(subnet)
  [ -n "$net" ] || die "network $EDGE_NET not found"
  echo "network: $net"
  if iptables -w -C DOCKER-USER -s "$net" -j DROP 2>/dev/null; then
    echo "egress:   BLOCKED (DOCKER-USER drop rule present)"
  else
    echo "egress:   NOT BLOCKED (no DOCKER-USER drop rule for $net)"
  fi
  iptables -w -S DOCKER-USER | sed 's/^/  /'
}

case "${1:-status}" in
  apply) apply ;;
  remove) remove ;;
  status) status ;;
  -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown command: $1 (apply|status|remove)" ;;
esac
