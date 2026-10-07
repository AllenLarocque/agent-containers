#!/usr/bin/env bash
# Usage: render-digests.sh <tag> <base-digest> <gis-digest> <bio-digest>   (prints digests.md to stdout)
set -euo pipefail
tag=${1:?tag}; base=${2:?base digest}; gis=${3:?gis digest}; bio=${4:?bio digest}
cat <<HDR
# Image digests

Copy a digest into a project's \`compose.yaml\` (\`image: ghcr.io/allenlarocque/spades-gis@sha256:…\`).
Updated by the \`publish\` workflow via PR — never edit by hand.

| image | tag | digest |
|---|---|---|
HDR
bt='`'  # literal backtick (markdown code span)
printf '| spades-base | %s | %s%s%s |\n' "$tag" "$bt" "$base" "$bt"
printf '| spades-gis | %s | %s%s%s |\n' "$tag" "$bt" "$gis" "$bt"
printf '| spades-bio | %s | %s%s%s |\n' "$tag" "$bt" "$bio" "$bt"
