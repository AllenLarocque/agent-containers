#!/usr/bin/env bash
# The fetch engine end to end inside spades-fetcher, with no network (--network none) and Chromium's
# sandbox ON. Run by scripts/build-publish.sh with the seccomp profile and the engine's test fixtures
# mounted read-only at /fetcher-test (images/fetcher/engine/test: the fixture server that plays doi.org
# and the publishers on loopback addresses; nothing from it is in the image).
#
# This starts the pieces itself (Xvfb, the fixture server, the engine's runLoop) instead of going
# through the entry point: the entry point reads /etc/fetcher/config, which accepts only an https
# resolver, and the fixture server is plain http on loopback. Everything else is the production
# code: runLoop and openBrowser from /opt/fetcher, with the sandbox left at its default (on).
set -uo pipefail
fail=0
ok()   { echo "OK:   $*"; }
bad()  { echo "FAIL: $*"; fail=1; }
check(){ local d="$1"; shift; local out rc=0
  out=$("$@" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then ok "$d"; else bad "$d (exit $rc)"; printf '%s\n' "$out" | tail -n 30 | sed 's/^/    | /'; fi; }

FX=/fetcher-test
check "fixtures mounted at $FX" test -f "$FX/fixture-server.mjs" -a -f "$FX/fixtures/paper.pdf"
check "network is off" bash -c '! curl -sS -m 5 -o /dev/null https://doi.org'

Xvfb :99 -screen 0 1280x900x24 -nolisten tcp >/dev/null 2>&1 &
for _ in $(seq 50); do [ -e /tmp/.X11-unix/X99 ] && break; sleep 0.1; done
check "Xvfb :99 up" test -e /tmp/.X11-unix/X99

w=$(mktemp -d)
mkdir -p "$w/papers/proj/_fetch/requests" "$w/profile" "$w/state" "$w/control"
# Two DOIs the fixture answers (a PDF; a bot check) and a URL line, which must never be fetched.
printf '10.5555/ok\n10.5555/check\nhttps://127.0.0.2/article/ok\n' > "$w/papers/proj/_fetch/requests/list.txt"

# shellcheck source=tests/smoke/lib-chromium-sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-chromium-sandbox.sh"

# One pass of the real loop against the fixture server, in the background. While it runs, the Chromium
# processes are sampled every 0.2 s (lib-chromium-sandbox.sh): one sample showing an unsandboxed renderer
# or a sandbox opt-out fails the run, and at least one sample must have judged renderers sandboxed.
node --input-type=module -e '
  import { runLoop } from "/opt/fetcher/fetcher.mjs";
  import { startFixtureServer, H } from "/fetcher-test/fixture-server.mjs";
  const w = process.argv[1];
  const fx = await startFixtureServer();
  const cfg = {
    resolver: fx.resolver, libraryPrefix: "", loginHosts: [H.L],
    caps: { gapMs: 0, hostGapMs: 0, perHost: 30, perDay: 100, libraryPerDay: 20, resolverPerDay: 300 },
    maxPdfBytes: 4096, timeouts: { navMs: 5000, settleMs: 500, downloadMs: 5000 },
  };
  try {
    await runLoop({ cfg, once: true, papersRoot: w + "/papers", profileDir: w + "/profile", stateDir: w + "/state",
                    downloadDir: w + "/dl", controlDir: w + "/control" });
  } finally { await fx.close(); }
  console.log("fixture requests: " + fx.log.map((e) => e.host + e.path).join(" "));
' "$w" > "$w/engine.log" 2>&1 &
engine=$!
good=0; badline=''
for _ in $(seq 300); do                       # 60 s
  kill -0 "$engine" 2>/dev/null || break
  line=$(chromium_sandbox_state); rc=$?
  case $rc in 0) good=$((good + 1)); last=$line ;; 1) badline=$line ;; esac
  sleep 0.2
done
if kill -0 "$engine" 2>/dev/null; then kill "$engine"; erc=124; else wait "$engine"; erc=$?; fi
engine_ok() { sed 's/^/    | /' "$w/engine.log"; [ "$erc" -eq 0 ]; }
check "engine: one pass finished within 60 s (exit $erc)" engine_ok
check "Chromium sandboxed throughout the run ($good sandboxed samples${last:+: $last})" \
  bash -c '[ -z "$1" ] && [ "$2" -gt 0 ] || { echo "${1:-no sample saw a sandboxed renderer}"; exit 1; }' _ "$badline" "$good"

S="$w/papers/proj/_fetch/status/list.tsv"
check "status file written" test -s "$S"
[ -s "$S" ] && sed 's/^/    | /' "$S"
check "10.5555/ok saved"                  bash -c 'awk -F"\t" "\$1 == \"10.5555/ok\" && \$2 == \"saved\"" "$1" | grep -q .' _ "$S"
check "10.5555/check needs-owner:check"   bash -c 'awk -F"\t" "\$1 == \"10.5555/check\" && \$2 == \"needs-owner:check\"" "$1" | grep -q .' _ "$S"
check "the URL line is bad-request (by line number, never echoed)" \
  bash -c 'awk -F"\t" "\$1 == \"line:3\" && \$2 == \"bad-request\"" "$1" | grep -q . && ! grep -q "https://" "$1"' _ "$S"
check "the PDF is in the paper's folder and starts %PDF-" bash -c '
  d=$(find "$1/papers/proj" -mindepth 1 -maxdepth 1 -type d -name "doi_10_5555_ok_*"); f="$d/paper.pdf"
  echo "pdf: ${f#"$1"/}"; [ -n "$d" ] && [ "$(head -c5 "$f")" = "%PDF-" ] && [ -f "$d/metadata.md" ] \
    && [ "$(find "$1/papers/proj" -name paper.pdf | wc -l)" = 1 ]' _ "$w"
check "nothing left in the download temp dir" bash -c '[ -z "$(ls -A "$1/dl" 2>/dev/null)" ]' _ "$w"

[ "$fail" -eq 0 ] && echo "SMOKE fetcher-offline: ALL PASSED" || { echo "SMOKE fetcher-offline: FAILURES"; exit 1; }
