#!/usr/bin/env bash
# Build images on the HOST (Docker required): base, then the requested children FROM it.
#   scripts/build-local.sh            # base + gis
#   scripts/build-local.sh bio        # base + bio
set -euo pipefail
cd "$(dirname "$0")/.."
docker build -t spades-base:local images/base
docker run --rm -v "$PWD/tests:/tests:ro" spades-base:local bash /tests/smoke/base.sh
for child in "${@:-gis}"; do
  docker build --build-arg BASE_IMAGE=spades-base:local -t "spades-$child:local" "images/$child"
  docker run --rm -v "$PWD/tests:/tests:ro" "spades-$child:local" bash "/tests/smoke/$child.sh"
done
