#!/usr/bin/env bash
# Two phases, run only in GitHub Actions (publish.yml against ghcr.io; ci.yml as a dry run against a local
# registry, so the dry run exercises the exact same logic).
#   build:   build + push spades-base, then spades-gis and spades-bio (children FROM base by REGISTRY digest),
#            then spades-research (FROM gis by registry digest), then spades-fetcher (FROM base by registry
#            digest). Only the dated tag is pushed; every image is smoke-tested BY DIGEST; then the five digests
#            are written to <digests-file>. `latest` is not touched.
#   promote: point `latest` at each digest in <digests-file> and read it back. Runs only after the workflow
#            has attested those digests, so a partial failure leaves `latest` untouched.
# Every digest comes from the build itself (buildx --metadata-file, containerimage.digest), never from reading
# a tag back: a tag can be overwritten between push and read-back by another run with write access to the
# registry; a digest is content-addressed, so nothing pushed later can change what it names.
# Usage: scripts/build-publish.sh build   <registry-prefix> <tag> <digests-file>
#        scripts/build-publish.sh promote <registry-prefix> <digests-file>
# <digests-file> is exactly five lines, in this order: `spades-base sha256:<hex>`, spades-gis, spades-bio, spades-research,
# spades-fetcher. promote refuses anything else.
# CI sets BUILD_CACHE=gha: layers come from / go to the GitHub Actions cache, and SOURCE_DATE_EPOCH is
# the last commit touching each image dir, so an unchanged base keeps its digest and the children's
# cache still hits. Unset (the real publish): base is built --pull --no-cache, as before.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
names=(spades-base spades-gis spades-bio spades-research spades-fetcher)
usage() { echo "usage: $0 build <registry-prefix> <tag> <digests-file> | $0 promote <registry-prefix> <digests-file>" >&2; exit 2; }

build() {  # $1 image name; rest: extra buildx args. Sets $digest to the digest buildx reports for the push.
  local img=$1; shift
  local -a extra=()
  if [ "${BUILD_CACHE:-}" = gha ]; then
    extra=(--cache-from "type=gha,scope=$img" --cache-to "type=gha,mode=max,scope=$img")
    SOURCE_DATE_EPOCH=$(git -C "$here" log -1 --format=%ct -- "images/$img"); export SOURCE_DATE_EPOCH
  elif [ "$img" = base ]; then
    extra=(--pull --no-cache)
  fi
  docker buildx build --push --metadata-file "$tmp/$img.json" "${extra[@]}" "$@" -t "$registry/spades-$img:$tag" "$here/images/$img"
  digest=$(jq -r '."containerimage.digest"' "$tmp/$img.json")
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "bad $img digest: '$digest'" >&2; exit 1; }
}

build_phase() {
  registry=${1:?registry prefix}; tag=${2:?tag}; out=${3:?digests file}
  rm -f "$out"   # a file at this path can only have come from this run
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

  # --pull is nearly moot: the rocker base is digest-pinned in the Dockerfile. The weekly rebuild patches
  # apt layers via --no-cache; the rocker OS layer only moves when someone bumps that pin.
  build base; base_digest=$digest

  # The child resolves its base from the registry by digest, so buildx (docker-container driver,
  # which cannot see the local daemon's images) works, and gis is pinned to the exact base published.
  build gis --build-arg "BASE_IMAGE=$registry/spades-base@$base_digest"; gis_digest=$digest
  build bio --build-arg "BASE_IMAGE=$registry/spades-base@$base_digest"; bio_digest=$digest
  build research --build-arg "BASE_IMAGE=$registry/spades-gis@$gis_digest"; research_digest=$digest
  build fetcher --build-arg "BASE_IMAGE=$registry/spades-base@$base_digest"; fetcher_digest=$digest

  # Smoke-test exactly what was pushed, pulled by digest (also proves pull-by-digest resolves).
  for img in base gis bio research fetcher; do
    case $img in base) d=$base_digest;; gis) d=$gis_digest;; bio) d=$bio_digest;; research) d=$research_digest;;
                 fetcher) d=$fetcher_digest;; esac
    local -a opts=()
    if [ "$img" = fetcher ]; then
      # Chromium's sandbox stays ON in the fetcher, and it needs unprivileged user namespaces, which Docker's
      # default seccomp profile blocks ("No usable sandbox!"). The profile is the one agent-up is to give the
      # fetcher container: moby/profiles seccomp/v0.3.0 default.json (Docker's default; tag dated 2026-11-02,
      # https://github.com/moby/profiles/blob/seccomp/v0.3.0/seccomp/default.json) with ONE rule added first,
      # allowing clone, setns and unshare: the rule Playwright's documented profile adds for Chromium
      # (https://github.com/microsoft/playwright/blob/v1.65.1/utils/docker/seccomp_profile.json, last changed
      # 2021-01-03; its other rules are an older copy of Docker's default). Taken 2026-11-16. No capability,
      # --ipc or other option is needed (tested): the smoke runs get exactly what production gets for the
      # sandbox. The engine's test fixtures (fixture server, pages, a PDF) are mounted for the offline run;
      # they are not in the image.
      opts=(--security-opt "seccomp=$here/project-template/config/fetcher-seccomp.json"
            -v "$here/images/fetcher/engine/test:/fetcher-test:ro")
    fi
    docker run --rm "${opts[@]}" -v "$here/tests:/tests:ro" "$registry/spades-$img@$d" bash "/tests/smoke/$img.sh"
    # Optional offline smoke (spec §6.1): tests/smoke/<img>-offline.sh runs with no network. It is a separate
    # file because the inherited base smoke installs the CLIs with npm and needs the network.
    if [ -f "$here/tests/smoke/$img-offline.sh" ]; then
      docker run --rm --network none "${opts[@]}" -v "$here/tests:/tests:ro" "$registry/spades-$img@$d" bash "/tests/smoke/$img-offline.sh"
    fi
  done

  printf 'spades-base %s\nspades-gis %s\nspades-bio %s\nspades-research %s\nspades-fetcher %s\n' \
    "$base_digest" "$gis_digest" "$bio_digest" "$research_digest" "$fetcher_digest" > "$out"
  echo "--- $out ---"; cat "$out"
}

promote() {  # $1 registry prefix, $2 digests file. Validates the whole file before touching the registry.
  local registry=${1:?registry prefix} file=${2:?digests file} i=0 line n d
  local -a digests=()
  [ -f "$file" ] || { echo "bad digests file: $file not found" >&2; exit 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    [[ $line =~ ^(spades-[a-z]+)\ (sha256:[0-9a-f]{64})$ ]] && [ "${BASH_REMATCH[1]}" = "${names[i]:-}" ] \
      || { echo "bad digests file: line $((i + 1)) is not '${names[i]:-<end>} sha256:<64 hex>'" >&2; exit 1; }
    digests+=("${BASH_REMATCH[2]}"); i=$((i + 1))
  done < "$file"
  [ "$i" -eq "${#names[@]}" ] || { echo "bad digests file: $i lines, expected ${#names[@]}" >&2; exit 1; }

  for i in "${!names[@]}"; do
    docker buildx imagetools create -t "$registry/${names[i]}:latest" "$registry/${names[i]}@${digests[i]}"
  done
  for i in "${!names[@]}"; do
    n=${names[i]}
    d=$(docker buildx imagetools inspect "$registry/$n:latest" --format '{{json .Manifest.Digest}}' | tr -d '"')
    [[ $d == "${digests[i]}" ]] || { echo "latest != $n digest ($d vs ${digests[i]})" >&2; exit 1; }
  done
}

case ${1:-} in
  build)   [ $# -eq 4 ] || usage; shift; build_phase "$@" ;;
  promote) [ $# -eq 3 ] || usage; shift; promote "$@" ;;
  *) usage ;;
esac
