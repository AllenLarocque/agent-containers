#!/usr/bin/env bash
# Print the manifest digest (sha256:<64 hex>) that ghcr.io/allenlarocque/<image>:<tag> points to; non-zero + a message on stderr on any failure.
# Anonymous (the images are public); curl only. `latest` is promoted only by scripts/build-publish.sh after smoke tests, so it is what agent-up/agent-new pin.
# Usage: registry-digest.sh <image-name, e.g. spades-bio> [tag, default latest]
set -euo pipefail
img=${1:-}; tag=${2:-latest}; owner=allenlarocque
[[ $img =~ ^spades-[a-z]+$ ]] || { echo "registry-digest: bad image name '$img' (want spades-<name>)" >&2; exit 2; }
[[ $tag =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || { echo "registry-digest: bad tag '$tag'" >&2; exit 2; }
accept='application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json'
cargs=(-fs --retry 3 --max-time 30)   # no -S: a retried-then-good request must not print errors; our messages say what failed

resp=$(curl "${cargs[@]}" "https://ghcr.io/token?scope=repository:$owner/$img:pull") \
  || { echo "registry-digest: could not get a pull token for $owner/$img from ghcr.io" >&2; exit 1; }
token=$(printf '%s' "$resp" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
[ -n "$token" ] || { echo "registry-digest: no token in the ghcr.io response for $owner/$img" >&2; exit 1; }

hdrs=$(curl "${cargs[@]}" -I -H "Authorization: Bearer $token" -H "Accept: $accept" \
  "https://ghcr.io/v2/$owner/$img/manifests/$tag") \
  || { echo "registry-digest: $owner/$img:$tag not found or unreachable on ghcr.io" >&2; exit 1; }
digest=$(printf '%s\n' "$hdrs" | tr -d '\r' | awk -F': ' 'tolower($1)=="docker-content-digest"{print $2; exit}')
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "registry-digest: bad or missing Docker-Content-Digest for $img:$tag ('$digest')" >&2; exit 1; }
printf '%s\n' "$digest"
