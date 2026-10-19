#!/usr/bin/env bash
# Verify a digests.md against ghcr.io, anonymously (the images are public): for every row, the digest
# resolves to a manifest, and the row's tag points to exactly that digest. Also checks the file's
# shape (the four images, once each) and that its header matches the committed skeleton.
# Usage: ci-verify-digests.sh <digests.md> <skeleton.md>
# Used by CI on publish's digests PRs instead of rebuilding: publish already built, pushed and
# smoke-tested exactly these digests (scripts/build-publish.sh smokes BY DIGEST before promoting).
set -euo pipefail
file=${1:?digests.md}; skeleton=${2:?skeleton digests.md (e.g. from the base branch)}
owner=allenlarocque
accept='application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'

diff <(head -7 "$skeleton") <(head -7 "$file") || { echo "header differs from the skeleton" >&2; exit 1; }
[ "$(grep -c '^| spades-' "$file")" = 4 ] || { echo "expected exactly 4 image rows" >&2; exit 1; }

# HEAD a manifest; print its Docker-Content-Digest (empty unless HTTP 200).
manifest_digest() {  # $1 image, $2 reference (tag or digest), $3 token
  curl -fsS -I --retry 3 -H "Authorization: Bearer $3" -H "Accept: $accept" \
    "https://ghcr.io/v2/$owner/$1/manifests/$2" | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2}'
}

rc=0
for img in spades-base spades-gis spades-bio spades-research; do
  row=$(grep -P "^\| $img \| " "$file" || true)
  re="^\| $img \| ([0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9a-f]{7}) \| \`(sha256:[0-9a-f]{64})\` \|$"
  [[ $row =~ $re ]] || { echo "FAIL: $img: malformed or missing row: '$row'"; rc=1; continue; }
  tag=${BASH_REMATCH[1]}; digest=${BASH_REMATCH[2]}
  token=$(curl -fsS --retry 3 "https://ghcr.io/token?scope=repository:$owner/$img:pull" | jq -r .token)
  by_digest=$(manifest_digest "$img" "$digest" "$token" || true)
  by_tag=$(manifest_digest "$img" "$tag" "$token" || true)
  if [ "$by_digest" != "$digest" ]; then
    echo "FAIL: $img@$digest does not resolve on ghcr.io (got '$by_digest')"; rc=1
  elif [ "$by_tag" != "$digest" ]; then
    echo "FAIL: $img:$tag points to '$by_tag', not $digest"; rc=1
  else
    echo "OK:   $img:$tag = $digest"
  fi
done
exit $rc
