#!/usr/bin/env bash
# Back up everything that cannot be regenerated: the database, the git data
# volume, the object-store blobs (optional, can be large), .env and certs/.
#
#   scripts/backup.sh [--with-media] [outdir]
#
# Safe to run on a live stack: Postgres is dumped with pg_dumpall (consistent),
# the object store and git volume are snapshotted after a short stop of the
# services that write to them.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OFFLINE_DIR="$(cd "$HERE/.." && pwd)"
COMPOSE="$OFFLINE_DIR/compose.yml"

WITH_MEDIA=0
OUTDIR=""
for arg in "$@"; do
  case "$arg" in
    --with-media) WITH_MEDIA=1 ;;
    *) OUTDIR="$arg" ;;
  esac
done
OUTDIR="${OUTDIR:-$OFFLINE_DIR/backups/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUTDIR"

say() { printf '\033[1;33m==>\033[0m %s\n' "$*"; }

project=$(docker compose -f "$COMPOSE" config --format json 2>/dev/null |
  sed -nE 's/.*"name":[[:space:]]*"([^"]+)".*/\1/p' | head -1)
project="${project:-buzz-offline}"

say "database -> $OUTDIR/postgres.sql.gz"
docker compose -f "$COMPOSE" exec -T postgres pg_dumpall -U "${POSTGRES_USER:-buzz}" |
  gzip -9 >"$OUTDIR/postgres.sql.gz"

say "secrets -> $OUTDIR/env.backup"
cp "$OFFLINE_DIR/.env" "$OUTDIR/env.backup"
chmod 600 "$OUTDIR/env.backup"

# TLS material: the private CA (ca.key is SECRET - keep this backup safe) and
# the leaf. Without them an upgrade or rebuild breaks every client's trust.
if [ -d "$OFFLINE_DIR/certs" ]; then
  say "certificates -> $OUTDIR/certs.tar.gz"
  tar -czf "$OUTDIR/certs.tar.gz" -C "$OFFLINE_DIR" certs
  chmod 600 "$OUTDIR/certs.tar.gz"
fi

say "git data volume -> $OUTDIR/git-data.tar.gz"
git_container=$(docker compose -f "$COMPOSE" ps -q relay)
if [ -n "$git_container" ]; then
  docker compose -f "$COMPOSE" stop relay >/dev/null
  mkdir -p "$OUTDIR/git-data"
  docker cp "$git_container:/data/git/." "$OUTDIR/git-data/"
  tar -czf "$OUTDIR/git-data.tar.gz" -C "$OUTDIR" git-data
  rm -rf "$OUTDIR/git-data"
  docker compose -f "$COMPOSE" up -d relay >/dev/null
fi

if [ "$WITH_MEDIA" = "1" ]; then
  say "object store -> $OUTDIR/media-data.tar.gz (this can be large)"
  silo_container=$(docker compose -f "$COMPOSE" ps -q silo)
  if [ -n "$silo_container" ]; then
    docker compose -f "$COMPOSE" stop silo >/dev/null
    mkdir -p "$OUTDIR/media-data"
    docker cp "$silo_container:/data/." "$OUTDIR/media-data/"
    tar -czf "$OUTDIR/media-data.tar.gz" -C "$OUTDIR" media-data
    rm -rf "$OUTDIR/media-data"
    docker compose -f "$COMPOSE" up -d silo >/dev/null
  fi
fi

say "done: $OUTDIR"
ls -lh "$OUTDIR" | sed 's/^/  /'
cat <<EOF

Restore outline (empty host, images already loaded):
  ./scripts/install.sh --no-start
  docker compose -f compose.yml up -d postgres
  gunzip -c postgres.sql.gz | docker compose -f compose.yml exec -T postgres psql -U buzz -d postgres
  docker compose -f compose.yml up -d
  (git/media tarballs: restore into the volumes before starting relay/silo)
EOF
