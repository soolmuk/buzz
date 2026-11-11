#!/usr/bin/env bash
# Package the offline bundle for one architecture.
#
#   scripts/package-images.sh <amd64|arm64> <release-tag> [outdir]
#
# Outputs, in <outdir> (default ./dist):
#   <name>-linux-<arch>.tar.gz   one gzipped `docker save` per image
#                                (core images + the TLS-profile caddy image)
#   images-<arch>.json           this arch's image IDs, for the merged lock
#   buzz-offline-bundle-<arch>.tar.gz  the offline/ directory itself
#   SHA256SUMS-<arch>            checksums for everything above
#
# Images are pulled by digest from offline/images.lock, so a moved tag can
# never change what a bundle contains. This is the same script CI runs; running
# it locally is how you build a bundle by hand.
set -euo pipefail

ARCH="${1:?usage: package-images.sh <amd64|arm64> <release-tag> [outdir]}"
RELEASE="${2:?usage: package-images.sh <amd64|arm64> <release-tag> [outdir]}"
OUTDIR="${3:-./dist}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OFFLINE_DIR="$(cd "$HERE/.." && pwd)"
LOCK="$OFFLINE_DIR/images.lock"

case "$ARCH" in
  amd64|arm64) ;;
  *) echo "unsupported arch: $ARCH (expected amd64 or arm64)" >&2; exit 2 ;;
esac

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }

mkdir -p "$OUTDIR"
OUTDIR="$(cd "$OUTDIR" && pwd)"

fragment=$(mktemp)
echo '{"ids":{}}' >"$fragment"

# Both the always-on images and the TLS-profile images (caddy) ship in the
# bundle; install.sh loads caddy only when OFFLINE_TLS=1.
while IFS=$'\t' read -r name repo digest; do
  ref="${repo}@${digest}"
  tag="buzz-offline/${name}:${RELEASE}"
  asset="${name}-linux-${ARCH}.tar.gz"

  echo "==> ${name}: pulling ${ref} (linux/${ARCH})"
  docker pull --platform "linux/${ARCH}" --quiet "$ref" >/dev/null
  docker tag "$ref" "$tag"

  image_id=$(docker image inspect --format '{{.Id}}' "$tag")
  echo "    image id ${image_id}"

  echo "==> ${name}: writing ${OUTDIR}/${asset}"
  docker save "$tag" | gzip -9 >"${OUTDIR}/${asset}.tmp"
  mv "${OUTDIR}/${asset}.tmp" "${OUTDIR}/${asset}"

  jq --arg name "$name" --arg id "$image_id" \
    '.ids[$name] = $id' "$fragment" >"$fragment.tmp" && mv "$fragment.tmp" "$fragment"

  # Drop the digest ref so the local daemon does not accumulate one per bundle.
  docker image rm "$ref" >/dev/null 2>&1 || true
done < <(jq -r '(.images + (.tls // []))[] | [.name, (.ref | sub(":.*$"; "")), .digest] | @tsv' "$LOCK")

jq --arg arch "$ARCH" --arg bundle "$RELEASE" \
  '{arch: $arch, bundle: $bundle, ids: .ids}' "$fragment" >"${OUTDIR}/images-${ARCH}.json"

# jq-free manifest for the installing host: name <TAB> local-tag <TAB> image-id.
jq -r --arg arch "$ARCH" --arg bundle "$RELEASE" \
  '.ids | to_entries[] | [.key, ("buzz-offline/" + .key + ":" + $bundle), .value] | @tsv' \
  "$fragment" >"${OUTDIR}/images-${ARCH}.txt"
rm -f "$fragment"

echo "==> bundling offline/ for ${ARCH}"
tar -czf "${OUTDIR}/buzz-offline-bundle-${ARCH}.tar.gz" \
  --exclude='./images' --exclude='./dist' --exclude='./.env' \
  -C "$(dirname "$OFFLINE_DIR")" "$(basename "$OFFLINE_DIR")"

echo "==> checksums"
(
  cd "$OUTDIR"
  shasum -a 256 ./*-"linux-${ARCH}".tar.gz "./images-${ARCH}.json" "./images-${ARCH}.txt" "./buzz-offline-bundle-${ARCH}.tar.gz" 2>/dev/null ||
    sha256sum ./*-"linux-${ARCH}".tar.gz "./images-${ARCH}.json" "./images-${ARCH}.txt" "./buzz-offline-bundle-${ARCH}.tar.gz"
) | sed 's|\./||' >"${OUTDIR}/SHA256SUMS-${ARCH}"

echo
echo "Packaged ${RELEASE} for linux/${ARCH} in ${OUTDIR}:"
ls -lh "$OUTDIR" | sed 's/^/  /'
