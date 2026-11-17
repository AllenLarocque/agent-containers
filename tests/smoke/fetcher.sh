#!/usr/bin/env bash
# Smoke test for spades-fetcher. Runs INSIDE the image as the default user, started by
# scripts/build-publish.sh with Chromium's seccomp profile
# (--security-opt seccomp=project-template/config/fetcher-seccomp.json) and NO extra capabilities.
# The fetcher has no agent: base's agent checks (agent-init, the CLIs, T3) do not apply and are not
# run; the checks that keep the container contained (user, sudo, setuid inventory, file capabilities,
# no vendor CLIs baked in) are repeated here.
#
# The entry point is run for real, with ONE substitution: `sudo` (used only for the firewall) is a
# stub that succeeds, because the smoke run has no NET_ADMIN and no network policy to set. The real
# firewall path is checked separately: without NET_ADMIN it fails and the entry point must exit with
# nothing started.
set -uo pipefail
fail=0
ok()   { echo "OK:   $*"; }
bad()  { echo "FAIL: $*"; fail=1; }
check(){ local d="$1"; shift; local out rc=0
  out=$("$@" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then ok "$d"; else bad "$d (exit $rc)"; printf '%s\n' "$out" | tail -n 30 | sed 's/^/    | /'; fi; }

EP=/usr/local/bin/fetcher-entrypoint
# The engine's own launch function (production code path) and the sandbox check page.
sandbox_page() {
  node --input-type=module -e '
    import { openBrowser } from "/opt/fetcher/lib/browser.mjs";
    import fs from "node:fs";
    const d = fs.mkdtempSync("/tmp/sbx-");
    const ctx = await openBrowser({ profileDir: d + "/profile", downloadDir: d + "/dl" });
    try {
      const p = ctx.pages()[0] ?? await ctx.newPage();
      await p.goto("about:blank");
      await p.goto("chrome://sandbox");
      await p.waitForTimeout(500);
      console.log(await p.locator("body").innerText());
    } finally { await ctx.close(); }'
}
# shellcheck source=tests/smoke/lib-chromium-sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib-chromium-sandbox.sh"
no_chromium() { local p; for p in /proc/[0-9]*; do [[ $(readlink "$p/exe" 2>/dev/null) == */chrome-linux64/chrome ]] && return 1; done; return 0; }

# ---- containment (from base: the parts that apply to a container with no agent) ----
[ "$(id -u)" = "1000" ] && [ "$(id -un)" = "agent" ] && ok "user agent uid 1000" || bad "user is $(id -un)/$(id -u), want agent/1000"
check "firewall script present"        test -x /usr/local/bin/init-firewall.sh
check "dnsmasq system user exists"     bash -c 'u=$(id -u dnsmasq) && [ "$u" -ne 0 ] && [ "$u" -ne 1000 ] && [ "$u" -lt 1000 ]'
sudo_cmds=$(sudo -n -l 2>/dev/null | awk 'f && NF {sub(/^[ \t]+/, ""); print} /may run the following commands/ {f=1}')
[ "$sudo_cmds" = "(root) NOPASSWD: /usr/local/bin/init-firewall.sh" ] && ok "sudo -l lists exactly the firewall script" \
  || bad "sudo -l commands are: $(printf '%q' "$sudo_cmds")"
check "sudo secure_path set"           bash -c 'sudo -n -l | grep -q "secure_path="'
check "sudo env_reset on"              bash -c 'sudo -n -l | grep -q "env_reset"'
# The same reviewed list as base: Playwright's Chromium needs no setuid helper (it uses user namespaces).
expect_suid='/usr/bin/chfn
/usr/bin/chsh
/usr/bin/gpasswd
/usr/bin/mount
/usr/bin/newgrp
/usr/bin/passwd
/usr/bin/su
/usr/bin/sudo
/usr/bin/umount'
got_suid=$( { find / -xdev -perm -4000 -type f 2>/dev/null || true; } | LC_ALL=C sort)
[ "$got_suid" = "$expect_suid" ] && ok "setuid binaries match base's reviewed list" \
  || { bad "setuid binaries differ from the reviewed list:"; diff <(echo "$expect_suid") <(echo "$got_suid") | sed 's/^/        /'; }
mapfile -t capdirs < <(find / -mindepth 1 -maxdepth 1 -type d ! -name proc ! -name sys ! -name dev)
got_caps=$( { getcap -r "${capdirs[@]}" 2>/dev/null || true; } | LC_ALL=C sort)
[ -z "$got_caps" ] && ok "no file capabilities anywhere" || { bad "file capabilities found:"; echo "$got_caps" | sed 's/^/        /'; }
check "Claude Code NOT in the image"   bash -c '[ -z "$(find / -xdev \( -path /proc -o -path /sys \) -prune -o -path "*@anthropic-ai/claude-code*" -print -quit 2>/dev/null)" ]'
check "Codex NOT in the image"         bash -c '[ -z "$(find / -xdev \( -path /proc -o -path /sys \) -prune -o -path "*@openai/codex*" -print -quit 2>/dev/null)" ]'

# ---- the fetcher's contents ----
check "node 22"                        bash -c 'v=$(node --version) && echo "$v" && [[ $v == v22.* ]]'
check "engine at /opt/fetcher, root-owned, not agent-writable" bash -c '
  for f in /opt/fetcher /opt/fetcher/fetcher.mjs /opt/fetcher/lib /opt/fetcher/node_modules; do
    [ -e "$f" ] && [ "$(stat -c %U "$f")" = root ] && [ ! -w "$f" ] || { echo "bad: $f"; exit 1; }; done'
check "playwright installed is the version package.json pins" bash -c '
  want=$(jq -r .dependencies.playwright /opt/fetcher/package.json); got=$(jq -r .version /opt/fetcher/node_modules/playwright/package.json)
  echo "pinned $want, installed $got"; [ -n "$want" ] && [ "$want" = "$got" ]'
check "production dependencies only: no test files, no dev tooling" bash -c '
  [ ! -e /opt/fetcher/test ] && [ -z "$(find /opt/fetcher -name "*.test.mjs" -print -quit)" ]
  [ "$(jq -r "(.devDependencies // {}) | length" /opt/fetcher/package.json)" = 0 ]'
check "Chromium for exactly the pinned Playwright revision" bash -c '
  rev=$(jq -r ".browsers[] | select(.name == \"chromium\") | .revision" /opt/fetcher/node_modules/playwright-core/browsers.json)
  echo "revision $rev"; [ -x "$PLAYWRIGHT_BROWSERS_PATH/chromium-$rev/chrome-linux64/chrome" ]'
check "Xvfb, x11vnc, noVNC, websockify present" bash -c 'command -v Xvfb && command -v x11vnc && command -v websockify && test -f /usr/share/novnc/vnc.html'
# (Playwright's library under node_modules contains the string: it is what chromiumSandbox: false adds.)
check "no --no-sandbox or test sandbox switch in the engine, entry point or fetcherctl" \
  bash -c '! grep -rIl -e "--no-sandbox" -e FETCHER_TEST_SANDBOX -e "chromiumSandbox: *false" /opt/fetcher --exclude-dir=node_modules "$1" "$(command -v fetcherctl)"' _ "$EP"
check "paths: profile and state dirs, control dir, papers root agent-owned; /etc/fetcher root-owned" bash -c '
  for d in /home/agent/.fetcher /home/agent/.fetcher/profile /home/agent/.fetcher/state /run/fetcher /papers /tmp/fetcher-dl; do
    [ -d "$d" ] && [ "$(stat -c %U "$d")" = agent ] || { echo "bad: $d"; exit 1; }; done
  [ "$(stat -c %U:%a /etc/fetcher)" = root:755 ]'
check "fetcher-entrypoint installed and executable (the image CMD)" test -x "$EP"

# ---- the entry point never starts an agent ----
# Every command line, comments dropped: no agent-init, agent-t3, agent-entrypoint, claude, codex, t3 or install-*.
check "entry point names no agent program" bash -c '! sed "s/#.*//" "$1" | grep -nE "agent-init|agent-t3|agent-entrypoint|agent-rstudio|install-agent|(^|[^a-z0-9-])(claude|codex|t3)([^a-z0-9-]|$)"' _ "$EP"
check "entry point: firewall first, Xvfb directly (never xvfb-run), engine last via exec" bash -c '
  body=$(sed "s/#.*//" "$1" | grep -v "^[[:space:]]*$")
  fw=$(grep -n "sudo /usr/local/bin/init-firewall.sh" <<<"$body" | head -n1 | cut -d: -f1)
  xv=$(grep -n "Xvfb :99" <<<"$body" | head -n1 | cut -d: -f1)
  ex=$(grep -n "^[[:space:]]*exec node /opt/fetcher/fetcher.mjs" <<<"$body" | cut -d: -f1)
  [ -n "$fw" ] && [ -n "$xv" ] && [ -n "$ex" ] && [ "$fw" -lt "$xv" ] && [ "$xv" -lt "$ex" ] && ! grep -q xvfb-run <<<"$body"
  grep -q "init-firewall.sh || " <<<"$body"' _ "$EP"

# Without NET_ADMIN the real firewall fails: the entry point must exit non-zero with nothing started.
fw_fail_closed() {
  local out rc=0
  out=$(timeout 120 "$EP" 2>&1) || rc=$?
  printf '%s\n' "$out" | tail -n 5
  [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] || { echo "entry point exit $rc"; return 1; }
  grep -q "firewall setup FAILED" <<<"$out" || return 1
  ! pgrep -x Xvfb && ! pgrep -f "/opt/fetcher/fetcher.mjs" && no_chromium
}
check "entry point: the firewall failing stops it, nothing started" fw_fail_closed

# The rest of the entry point, for real (firewall stubbed: see the header).
stub=$(mktemp -d)
printf '#!/bin/sh\necho "[smoke] sudo stub: firewall skipped (no NET_ADMIN in the smoke run)"\nexit 0\n' > "$stub/sudo"
chmod +x "$stub/sudo"
eplog=$(mktemp)
PATH="$stub:$PATH" "$EP" >"$eplog" 2>&1 &
ep_pid=$!
sleep 20
check "after 20 s the engine is still running (as the entry point's own process)" \
  bash -c 'kill -0 "$1" && grep -q "/opt/fetcher/fetcher.mjs" "/proc/$1/cmdline"' _ "$ep_pid"
check "after 20 s Xvfb :99 is running, no TCP listener" bash -c 'pgrep -a -x Xvfb | grep -q ":99" && pgrep -a -x Xvfb | grep -q -- "-nolisten tcp"'
# A renderer may be between pages at any one instant: poll up to ~15 s for one before judging (exit 2 =
# nothing to judge yet; 0 or 1 is a verdict and ends the wait at once).
sandbox_when_renderer() { local i out rc
  for i in $(seq 30); do
    out=$(chromium_sandbox_state); rc=$?
    [ "$rc" -ne 2 ] && break
    sleep 0.5
  done
  echo "$out (after $((i / 2)) s of polling)"; return "$rc"
}
check "after 20 s the engine's Chromium is sandboxed (kernel view: renderers in own user+PID ns, extra seccomp)" sandbox_when_renderer
# No agent program running: exact program names (a bare "t3" substring also matches random profile paths).
check "after 20 s no t3, claude, codex or agent-init process" \
  bash -c '! pgrep -a -f "(^|[/ ])(t3|claude|codex|agent-init\.sh|agent-t3|agent-entrypoint)( |$)"'
check "no viewer without /etc/fetcher/view-password" bash -c '[ ! -e /etc/fetcher/view-password ] && ! pgrep -x x11vnc && ! pgrep -f "[w]ebsockify"'
# chrome://sandbox from the engine's own launch function: "adequately sandboxed" only with the namespace
# sandbox (layer 1) AND seccomp-BPF (layer 2) up. Chromium refuses to start sandboxed without them
# ("No usable sandbox!"), so a fallback would fail the launch or this page, never pass silently.
sbx_ok() {
  local t; t=$(sandbox_page) || { echo "$t"; return 1; }
  echo "$t"
  grep -q "You are adequately sandboxed" <<<"$t" && grep -qE "Layer 1 Sandbox[[:space:]]+Namespace" <<<"$t" \
    && grep -qE "Seccomp-BPF sandbox[[:space:]]+Yes" <<<"$t" && grep -qE "PID namespaces[[:space:]]+Yes" <<<"$t" \
    && grep -qE "Network namespaces[[:space:]]+Yes" <<<"$t"
}
check "Chromium (engine's openBrowser, headed, Xvfb) reports: adequately sandboxed" sbx_ok

# ---- fetcherctl: validated arguments, writes only under /run/fetcher ----
check "fetcherctl rejects a bad host and writes nothing" bash -c '
  ! fetcherctl retry check "a b;rm" 2>/dev/null && ! fetcherctl retry check "../x" 2>/dev/null && ! fetcherctl nope 2>/dev/null \
    && [ ! -e /run/fetcher/retry ]'
check "fetcherctl pause / resume / retry" bash -c '
  fetcherctl pause && [ -f /run/fetcher/pause ] && fetcherctl resume && [ ! -e /run/fetcher/pause ] \
    && fetcherctl retry check www.example.org && [ "$(cat /run/fetcher/retry)" = "check www.example.org" ] && rm /run/fetcher/retry'

kill "$ep_pid" 2>/dev/null; wait "$ep_pid" 2>/dev/null
if [ "$fail" -ne 0 ]; then echo "--- entry point log (tail)"; tail -n 30 "$eplog" | sed 's/^/    | /'; fi
[ "$fail" -eq 0 ] && echo "SMOKE fetcher: ALL PASSED" || { echo "SMOKE fetcher: FAILURES"; exit 1; }
