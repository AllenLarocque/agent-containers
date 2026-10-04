#!/usr/bin/env bash
# Build + push spades-base then spades-gis (gis FROM base by REGISTRY digest), then render digests.md.
# Used by both the publish workflow (REGISTRY=ghcr.io/allenlarocque) and the CI dry-run
# (REGISTRY=localhost:5000/allenlarocque), so the dry-run exercises the exact same logic.
# Usage: scripts/build-publish.sh <registry-prefix> <tag> [digests-out-file]
set -euo pipefail
registry=${1:?registry prefix}; tag=${2:?tag}; out=${3:-digests.md}
here=$(cd "$(dirname "$0")/.." && pwd)

digest_of() {  # manifest digest of a pushed ref, read back from the registry
  docker buildx imagetools inspect "$1" --format '{{json .Manifest.Digest}}' | tr -d '"'
}

docker buildx build --pull --no-cache --push \
  -t "$registry/spades-base:$tag" -t "$registry/spades-base:latest" "$here/images/base"
base_digest=$(digest_of "$registry/spades-base:$tag")
[[ $base_digest =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "bad base digest: '$base_digest'" >&2; exit 1; }

# The child resolves its base from the registry by digest, so buildx (docker-container driver,
# which cannot see the local daemon's images) works, and gis is pinned to the exact base published.
docker buildx build --push --build-arg "BASE_IMAGE=$registry/spades-base@$base_digest" \
  -t "$registry/spades-gis:$tag" -t "$registry/spades-gis:latest" "$here/images/gis"
gis_digest=$(digest_of "$registry/spades-gis:$tag")
[[ $gis_digest =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "bad gis digest: '$gis_digest'" >&2; exit 1; }

"$here/scripts/render-digests.sh" "$tag" "$base_digest" "$gis_digest" > "$out"
echo "--- $out ---"; cat "$out"
