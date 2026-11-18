#!/usr/bin/env bash
# Run the fetcher engine tests inside the pinned Playwright image (no Node needed on
# the host). Step 1 installs dependencies with the network on; step 2 runs the tests
# with no network at all (the fixture server listens on the container's loopback).
# Exits non-zero if either step fails.
#
# The browser tests run a headed Chromium, so step 2 starts Xvfb itself (not xvfb-run,
# which hangs as PID 1 in a container). Chromium's sandbox cannot start under Docker's
# default seccomp profile, so FETCHER_TEST_SANDBOX=off turns it off for THIS test
# container only; the engine's default stays on, and the fetcher image supplies the
# seccomp profile that lets it run there.
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

docker run "${common[@]}" --network none -e DISPLAY=:99 -e FETCHER_TEST_SANDBOX=off "$image" \
  sh -c 'Xvfb :99 -screen 0 1280x900x24 -nolisten tcp >/dev/null 2>&1 &
         for i in $(seq 50); do [ -e /tmp/.X11-unix/X99 ] && break; sleep 0.1; done
         node --test test/*.test.mjs'
