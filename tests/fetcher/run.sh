#!/usr/bin/env bash
# Run the fetcher engine tests inside the pinned Playwright image (no Node needed on
# the host). Step 1 installs dependencies with the network on; step 2 runs the tests
# with no network at all. Exits non-zero if either step fails.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
engine="$root/images/fetcher/engine"
# Keep in step with "playwright" in images/fetcher/engine/package.json.
image="mcr.microsoft.com/playwright:v1.65.1-noble"

common=(--rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$engine:/work" -w /work)

docker run "${common[@]}" -e PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 "$image" \
  sh -c 'if [ -f package-lock.json ]; then npm ci --ignore-scripts; else npm install --ignore-scripts; fi'

docker run "${common[@]}" --network none "$image" \
  sh -c 'node --test test/*.test.mjs'
