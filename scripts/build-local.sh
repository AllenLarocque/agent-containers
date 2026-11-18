#!/usr/bin/env bash
# Build images on the HOST (Docker required): base, then the requested children FROM it.
#   scripts/build-local.sh            # base + gis
#   scripts/build-local.sh bio        # base + bio
#   scripts/build-local.sh research   # base + gis + research
#   scripts/build-local.sh fetcher    # base + fetcher (smoke runs with the Chromium seccomp profile, as in build-publish.sh)
set -euo pipefail
cd "$(dirname "$0")/.."
docker build -t spades-base:local images/base
docker run --rm -v "$PWD/tests:/tests:ro" spades-base:local bash /tests/smoke/base.sh
for child in "${@:-gis}"; do
  parent=base
  if [ "$child" = research ]; then
    # research is FROM gis: build and smoke gis first.
    docker build --build-arg BASE_IMAGE=spades-base:local -t spades-gis:local images/gis
    docker run --rm -v "$PWD/tests:/tests:ro" spades-gis:local bash /tests/smoke/gis.sh
    parent=gis
  fi
  docker build --build-arg "BASE_IMAGE=spades-$parent:local" -t "spades-$child:local" "images/$child"
  opts=()
  if [ "$child" = fetcher ]; then
    # The same options build-publish.sh gives the fetcher's smoke runs (see the comment there).
    opts=(--security-opt "seccomp=$PWD/project-template/config/fetcher-seccomp.json" -v "$PWD/images/fetcher/engine/test:/fetcher-test:ro")
  fi
  docker run --rm "${opts[@]}" -v "$PWD/tests:/tests:ro" "spades-$child:local" bash "/tests/smoke/$child.sh"
  if [ "$child" = fetcher ]; then
    docker run --rm --network none "${opts[@]}" -v "$PWD/tests:/tests:ro" "spades-$child:local" bash "/tests/smoke/$child-offline.sh"
  fi
done
