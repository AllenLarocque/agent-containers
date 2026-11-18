#!/usr/bin/env bash
# The fetch engine end to end inside spades-fetcher, with no network (--network none) and Chromium's
# sandbox ON. Run by scripts/build-publish.sh with the seccomp profile and the engine's test fixtures
# mounted read-only at /fetcher-test (images/fetcher/engine/test: the fixture server that plays doi.org
# and the publishers on loopback addresses; nothing from it is in the image).
#
# This starts the pieces itself (Xvfb, the fixture server, the engine's runLoop) instead of going
# through the entry point: the entry point reads /etc/fetcher/config, which accepts only an https
# resolver, and the fixture server is plain http on loopback. Everything else is the production
# code: runLoop and the browsers from /opt/fetcher, with the sandbox left at its default (on). The one
# test-only setting is testOnlyAllow: the fixture's loopback hosts through the browsers' loopback
# guard (only a caller's options can set it; the command line, the config and the environment cannot).
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
mkdir -p "$w/papers/proj/_fetch/requests" "$w/profiles" "$w/state" "$w/control"
# Two DOIs the fixture answers (a PDF; a bot check), a URL line, which must never be fetched, a page that
# stops answering (a busy loop: cut off by the deadline, the browser killed and relaunched) and a paper
# after it, which must still be saved.
printf '10.5555/ok\n10.5555/check\nhttps://127.0.0.2/article/ok\n10.5555/busy\n10.5555/good1\n' > "$w/papers/proj/_fetch/requests/list.txt"

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
    await runLoop({ cfg, once: true, papersRoot: w + "/papers", profilesDir: w + "/profiles", stateDir: w + "/state",
                    downloadDir: w + "/dl", controlDir: w + "/control", testOnlyAllow: fx.allow });
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
check "10.5555/busy not-available:timeout (sandbox on), and 10.5555/good1 after it saved" bash -c '
  awk -F"\t" "\$1 == \"10.5555/busy\" && \$2 == \"not-available:timeout\"" "$1" | grep -q . \
    && awk -F"\t" "\$1 == \"10.5555/good1\" && \$2 == \"saved\"" "$1" | grep -q .' _ "$S"
check "the URL line is bad-request (by line number, never echoed)" \
  bash -c 'awk -F"\t" "\$1 == \"line:3\" && \$2 == \"bad-request\"" "$1" | grep -q . && ! grep -q "https://" "$1"' _ "$S"
check "the PDF is in the paper's folder and starts %PDF-" bash -c '
  d=$(find "$1/papers/proj" -mindepth 1 -maxdepth 1 -type d -name "doi_10_5555_ok_*"); f="$d/paper.pdf"
  echo "pdf: ${f#"$1"/}"; [ -n "$d" ] && [ "$(head -c5 "$f")" = "%PDF-" ] && [ -f "$d/metadata.md" ] \
    && [ "$(find "$1/papers/proj" -name paper.pdf | wc -l)" = 2 ]' _ "$w"
check "nothing left in the download temp dir" bash -c '[ -z "$(ls -A "$1/dl" 2>/dev/null)" ]' _ "$w"

# ---- the owner's view (fetcher-view, as the entry point starts it when agent-up mounts a password file) ----
# The smoke run has no /etc/fetcher/view-password (root-owned folder, no extra docker options), so the same script is
# started on a temp password file. Xvfb :99 is still up from above.
check "no password file: fetcher-view refuses, nothing listens on 5900 or 3773" bash -c '
  ! /usr/local/bin/fetcher-view "$1/no-such-password" && sleep 1 && ! ss -Hltn | grep -Eq ":(5900|3773)\b"' _ "$w"
( umask 077; printf 'Ab3dE6gH' > "$w/view-password" )
/usr/local/bin/fetcher-view "$w/view-password" > "$w/view.log" 2>&1
for _ in $(seq 50); do curl -fsS -o /dev/null -m 1 http://127.0.0.1:3773/vnc.html 2>/dev/null && break; sleep 0.2; done
check "viewer: noVNC answers on 3773" curl -fsS -o /dev/null -m 5 http://127.0.0.1:3773/vnc.html
check "viewer: x11vnc listens on 127.0.0.1:5900 only; 3773 is the only other new listener" bash -c '
  l=$(ss -Hltn | awk "{print \$4}" | sort -u); echo "$l"
  grep -qx "127.0.0.1:5900" <<<"$l" && ! grep -v "^127.0.0.1:5900$" <<<"$l" | grep -q ":5900$" \
    && grep -Eqx "(0.0.0.0|\*|\[::\]):3773" <<<"$l" \
    && [ -z "$(grep -Ev "^127.0.0.1:5900$|:3773$" <<<"$l")" ]'
# RFB handshake far enough to see the security types offered: VNC authentication (2) only, never None (1).
check "viewer: the VNC server requires its password (security types offered: 2 only)" node -e '
  const s = require("net").connect(5900, "127.0.0.1"); let buf = Buffer.alloc(0), sent = false;
  const done = (ok, m) => { console.log(m); s.destroy(); process.exit(ok ? 0 : 1); };
  s.on("data", (d) => { buf = Buffer.concat([buf, d]);
    if (!sent && buf.length >= 12) { sent = true; console.log("server: " + buf.subarray(0, 11)); s.write(buf.subarray(0, 12)); buf = buf.subarray(12); }
    else if (sent && buf.length >= 1 && buf.length >= 1 + buf[0]) {
      const types = [...buf.subarray(1, 1 + buf[0])]; done(types.length > 0 && types.every((t) => t === 2), "security types: " + types.join(",")); } });
  s.on("error", (e) => done(false, String(e))); setTimeout(() => done(false, "timeout"), 5000);'
check "viewer: x11vnc runs with -localhost -noremote -novncconnect -noclipboard -nosel and a password file, never -nopw" bash -c '
  c=$(tr "\0" " " < "/proc/$(pgrep -x x11vnc | head -n1)/cmdline"); echo "$c"
  for o in -localhost -noremote -novncconnect -noclipboard -nosel; do grep -qE -- "(^| )$o( |$)" <<<"$c" || exit 1; done
  grep -qE -- " -(passwdfile|rfbauth) " <<<"$c" && ! grep -qE -- "(^| )-nopw( |$)" <<<"$c"'
check "viewer: x11vnc does not answer remote-control queries over the display (x11vnc -Q ping)" bash -c '
  out=$(timeout 15 x11vnc -display :99 -Q ping 2>/dev/null); echo "answer: [$out]"; ! grep -q "ans=ping" <<<"$out"'
check "viewer: no directory listings (/ and /app/ redirect to vnc.html); /vnc.html answers" bash -c '
  for u in / /app/ /core/; do b=$(curl -fsS -m 5 "http://127.0.0.1:3773$u") || exit 1; ! grep -qi "directory listing" <<<"$b" && grep -q "url=/vnc.html" <<<"$b" || { echo "$u: $b" | head -n 3; exit 1; }; done
  curl -fsS -m 5 http://127.0.0.1:3773/vnc.html | grep -qi "<title>noVNC"'
check "viewer: the password is in no log and on no command line" bash -c '
  ! grep -rq "Ab3dE6g[H]" /tmp/fetcher-view "$1/view.log" && ! grep -qa "Ab3dE6g[H]" /proc/[0-9]*/cmdline' _ "$w"
pkill -x x11vnc; pkill -f "[w]ebsockify"; sleep 1
check "viewer stopped: nothing listens on 5900 or 3773" bash -c '! ss -Hltn | grep -Eq ":(5900|3773)\b"'

[ "$fail" -eq 0 ] && echo "SMOKE fetcher-offline: ALL PASSED" || { echo "SMOKE fetcher-offline: FAILURES"; exit 1; }
