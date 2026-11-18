#!/usr/bin/env bash
set -euo pipefail
fail=0
# On failure, print the command, its exit code and the last 40 lines of its output (stdout+stderr).
check(){
  local d="$1"; shift; local out rc=0
  out=$("$@" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then echo "OK:   $d"; else
    echo "FAIL: $d (exit $rc): $*"; printf '%s\n' "$out" | tail -n 40 | sed 's/^/    | /'; fail=1
  fi
}
check "inherits gis smoke"  bash /tests/smoke/gis.sh
check "paper-tools MANIFEST exists and is readable by agent" bash -c 'id -un | grep -qx agent && test -r /opt/paper-tools/MANIFEST'
check "README readable by agent, names every MANIFEST tool" bash -c 'test -r /opt/paper-tools/README.md && for t in pdftotext qpdf tesseract ocrmypdf grobid paper-search; do grep -q "$t" /opt/paper-tools/README.md || { echo "README lacks $t"; exit 1; }; done'
check "README: Sci-Hub tools are denied, downloads go to downloads/papers/" bash -c 'grep -q "Sci-Hub" /opt/paper-tools/README.md && grep -q "downloads/papers/" /opt/paper-tools/README.md'
# agent-init with the research profile (a stand-in file: /etc/firewall/profile is root's): Claude itself
# reads the registration and the server connects (`claude mcp get` starts it). The base smoke's agent-init
# (no profile file = builder, /tmp/cc) must not have it. Codex does not get the server.
check "agent-init (research): claude sees paper-search, connected" bash -c '
  set -e; d=$(mktemp -d); printf "PROFILE=research\n" > "$d/profile"
  AGENT_PROFILE_FILE="$d/profile" CLAUDE_CONFIG_DIR="$d/cc" CODEX_HOME="$d/codex" /usr/local/bin/agent-init.sh
  out=$(cd "$d" && CLAUDE_CONFIG_DIR="$d/cc" timeout 120 claude mcp get paper-search 2>&1) || true; echo "$out"
  grep -q "Connected" <<<"$out"
  if grep -q paper-search "$d/codex/config.toml"; then echo "codex config names paper-search"; exit 1; fi'
check "agent-init (builder): no paper-search for claude" bash -c 'out=$(cd /tmp && CLAUDE_CONFIG_DIR=/tmp/cc claude mcp get paper-search 2>&1); echo "$out"; grep -q "No MCP server named \"paper-search\"" <<<"$out"'
echo "INFO: paper tools: $(grep -c . /opt/paper-tools/MANIFEST || true) installed"
[ "$fail" -eq 0 ] && echo "SMOKE research: ALL PASSED" || { echo "SMOKE research: FAILURES"; exit 1; }
