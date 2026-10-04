#!/usr/bin/env bash
# Build + push spades-base then spades-gis and spades-bio (children FROM base by REGISTRY digest), then render digests.md.
# Used by both the publish workflow (REGISTRY=ghcr.io/allenlarocque) and the CI dry-run
# (REGISTRY=localhost:5000/allenlarocque), so the dry-run exercises the exact same logic.
# Only the dated tag is pushed during builds; both images are smoke-tested BY DIGEST, and only then
# is `latest` promoted (so a partial failure leaves `latest` untouched).
# Usage: scripts/build-publish.sh <registry-prefix> <tag> [digests-out-file]
set -euo pipefail
registry=${1:?registry prefix}; tag=${2:?tag}; out=${3:-digests.md}
here=$(cd "$(dirname "$0")/.." && pwd)

digest_of() {  # manifest digest of a pushed ref, read back from the registry
  docker buildx imagetools inspect "$1" --format '{{json .Manifest.Digest}}' | tr -d '"'
}

# --pull is nearly moot: the rocker base is digest-pinned in the Dockerfile. The weekly rebuild patches
# apt layers via --no-cache; the rocker OS layer only moves when someone bumps that pin.
docker buildx build --pull --no-cache --push \
  -t "$registry/spades-base:$tag" "$here/images/base"
base_digest=$(digest_of "$registry/spades-base:$tag")
[[ $base_digest =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "bad base digest: '$base_digest'" >&2; exit 1; }

# The child resolves its base from the registry by digest, so buildx (docker-container driver,
# which cannot see the local daemon's images) works, and gis is pinned to the exact base published.
docker buildx build --push --build-arg "BASE_IMAGE=$registry/spades-base@$base_digest" \
  -t "$registry/spades-gis:$tag" "$here/images/gis"
gis_digest=$(digest_of "$registry/spades-gis:$tag")
[[ $gis_digest =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "bad gis digest: '$gis_digest'" >&2; exit 1; }

docker buildx build --push --build-arg "BASE_IMAGE=$registry/spades-base@$base_digest" \
  -t "$registry/spades-bio:$tag" "$here/images/bio"
bio_digest=$(digest_of "$registry/spades-bio:$tag")
[[ $bio_digest =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "bad bio digest: '$bio_digest'" >&2; exit 1; }

# Smoke-test exactly what was pushed, pulled by digest (also proves pull-by-digest resolves).
for img in base gis bio; do
  case $img in base) d=$base_digest;; gis) d=$gis_digest;; bio) d=$bio_digest;; esac
  docker run --rm -v "$here/tests:/tests:ro" "$registry/spades-$img@$d" bash "/tests/smoke/$img.sh"
done

# Promote latest only after all built and smoke-passed.
docker buildx imagetools create -t "$registry/spades-base:latest" "$registry/spades-base@$base_digest"
docker buildx imagetools create -t "$registry/spades-gis:latest" "$registry/spades-gis@$gis_digest"
docker buildx imagetools create -t "$registry/spades-bio:latest" "$registry/spades-bio@$bio_digest"
[[ $(digest_of "$registry/spades-base:latest") == "$base_digest" ]] || { echo "latest != base digest" >&2; exit 1; }
[[ $(digest_of "$registry/spades-gis:latest") == "$gis_digest" ]] || { echo "latest != gis digest" >&2; exit 1; }
[[ $(digest_of "$registry/spades-bio:latest") == "$bio_digest" ]] || { echo "latest != bio digest" >&2; exit 1; }

"$here/scripts/render-digests.sh" "$tag" "$base_digest" "$gis_digest" "$bio_digest" > "$out"
echo "--- $out ---"; cat "$out"
