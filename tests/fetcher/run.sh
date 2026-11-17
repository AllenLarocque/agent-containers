#!/usr/bin/env bash
# Run the fetcher engine tests inside the pinned Playwright image (no Node needed on
# the host). Step 1 installs dependencies with the network on; step 2 runs the tests
# with no network at all. Exits non-zero if either step fails.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
engine="$root/images/fetcher/engine"
# The Playwright version has one source: the pinned line in package.json.
pw="$(sed -n 's/^ *"playwright": *"\([0-9][0-9.]*\)".*/\1/p' "$engine/package.json")"
if [ -z "$pw" ]; then
  echo "run.sh: cannot read the pinned playwright version from $engine/package.json" >&2
  exit 1
fi
image="mcr.microsoft.com/playwright:v${pw}-noble"

common=(--rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$engine:/work" -w /work)

docker run "${common[@]}" -e PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 "$image" \
  sh -c 'if [ -f package-lock.json ]; then npm ci --ignore-scripts; else npm install --ignore-scripts; fi'

docker run "${common[@]}" --network none "$image" \
  sh -c 'node --test test/*.test.mjs'
