#!/usr/bin/env bash
# Tests for scripts/update-candidates.sh: pinned versions vs eligible (past-cooldown, stable, newer)
# upstream versions. gh and npm are stubbed on PATH with JSON fixtures; no network.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/update-candidates.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0

# Fixture repo: only the pin lines and the two package.json files.
R="$T/repo"; BIN="$T/bin"; FIX="$T/fix"
mkdir -p "$R/images/base/agent-clis/claude-code" "$R/images/base/agent-clis/codex" "$BIN" "$FIX"
printf 'FROM scratch\nARG T3_VERSION=0.1.0\nENV T3_PROTOCOL=2\n' > "$R/images/base/Dockerfile"
cp "$ROOT/images/base/agent-clis/claude-code/package.json" "$R/images/base/agent-clis/claude-code/"
cp "$ROOT/images/base/agent-clis/codex/package.json" "$R/images/base/agent-clis/codex/"
# Pin the fixtures regardless of what the real files hold.
echo '{"dependencies":{"@anthropic-ai/claude-code":"2.1.301"}}' > "$R/images/base/agent-clis/claude-code/package.json"
echo '{"dependencies":{"@openai/codex":"0.163.0"}}' > "$R/images/base/agent-clis/codex/package.json"

cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
[ -z "${GH_FAIL:-}" ] || { echo "gh: boom" >&2; exit 1; }
cat "$FIX/gh.json"
STUB
cat > "$BIN/npm" <<'STUB'
#!/usr/bin/env bash
[ "$1" = view ] && [ "$3" = time ] && [ "$4" = --json ] || { echo "unexpected npm args: $*" >&2; exit 2; }
[ -z "${NPM_FAIL:-}" ] || { echo "npm: boom" >&2; exit 1; }
cat "$FIX/npm-$(printf '%s' "$2" | tr '/@' '__').json"
STUB
chmod +x "$BIN/gh" "$BIN/npm"
export FIX PATH="$BIN:$PATH"
export UPDATE_NOW; UPDATE_NOW=$(date -u -d 2026-10-17T00:00:00Z +%s)

rel() { # rel <tag> <prerelease> <draft> <published_at>
  jq -n --arg t "$1" --argjson p "$2" --argjson d "$3" --arg a "$4" \
    '{tag_name:$t,prerelease:$p,draft:$d,published_at:$a}'; }
set_gh() { jq -s '.' > "$FIX/gh.json"; }
set_gh < <(rel v0.2.0 false false 2026-10-14T00:00:00Z; rel v0.3.0 false false 2026-10-16T00:00:00Z
           rel v0.4.0-rc.1 true false 2026-10-01T00:00:00Z; rel v0.0.45 false false 2026-09-01T00:00:00Z
           rel v0.5.0 false true 2026-10-01T00:00:00Z; rel nightly false false 2026-10-01T00:00:00Z)
echo '{"created":"2025-01-01T00:00:00.000Z","modified":"2026-10-16T00:00:00.000Z","2.1.301":"2026-10-01T00:00:00.000Z","2.1.300":"2026-09-01T00:00:00.000Z","2.2.0-beta.1":"2026-10-01T00:00:00.000Z","2.2.0":"2026-10-10T00:00:00.000Z","2.2.1":"2026-10-12T10:00:00.000Z","2.2.2":"2026-10-16T12:00:00.000Z"}' > "$FIX/npm-_anthropic-ai_claude-code.json"
echo '{"created":"2025-01-01T00:00:00.000Z","modified":"2026-10-16T00:00:00.000Z","0.163.0":"2026-10-01T00:00:00.000Z","0.164.0":"2026-10-14T00:00:00.000Z"}' > "$FIX/npm-_openai_codex.json"

out=$(cd "$R" && bash "$SCRIPT")
tab=$'\t'
check() { # check <line>: must appear exactly in the output
  if printf '%s\n' "$out" | grep -qxF -- "$1"; then echo "OK:   has ${1//$tab/ | }"
  else echo "FAIL: missing ${1//$tab/ | }"; fail=1; fi; }
absent() { # absent <regex>
  if printf '%s\n' "$out" | grep -qE -- "$1"; then echo "FAIL: unexpected /$1/"; fail=1
  else echo "OK:   no /$1/"; fi; }
refuses() { # refuses <desc> <stderr-pattern> <env assignment>
  local err rc=0
  err=$(cd "$R" && env "$3" bash "$SCRIPT" 2>&1 >/dev/null) || rc=$?
  if [ "$rc" = 1 ] && printf '%s' "$err" | grep -q -- "$2"; then echo "OK:   refuses: $1"
  else echo "FAIL: $1 (rc=$rc, stderr=$err)"; fail=1; fi; }

check "PINNED${tab}t3${tab}0.1.0"
check "PINNED${tab}claude-code${tab}2.1.301"
check "PINNED${tab}codex${tab}0.163.0"
check "PINNED${tab}t3-protocol${tab}2"
check "NEW${tab}t3${tab}0.2.0${tab}2026-10-14${tab}https://github.com/pingdotgg/t3code/releases/tag/v0.2.0"
absent "^NEW${tab}t3${tab}0.3.0"      # 1 day old: inside the cooldown
absent "^NEW${tab}t3${tab}0.4.0"      # prerelease
absent "^NEW${tab}t3${tab}0.5.0"      # draft
absent "^NEW${tab}t3${tab}0.0.45"     # older than the pin
absent "beta"                         # npm prerelease
absent "^NEW${tab}claude-code${tab}2.2.2"   # inside the cooldown
absent "^NEW${tab}claude-code${tab}2.1.300" # older than the pin
check "NEW${tab}claude-code${tab}2.2.0${tab}2026-10-10${tab}https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md"
check "NEW${tab}claude-code${tab}2.2.1${tab}2026-10-12${tab}https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md"
check "NEW${tab}codex${tab}0.164.0${tab}2026-10-14${tab}https://github.com/openai/codex/releases/tag/rust-v0.164.0"
order=$(printf '%s\n' "$out" | grep "^NEW${tab}claude-code" | cut -f3 | tr '\n' ' ')
if [ "$order" = "2.2.0 2.2.1 " ]; then echo "OK:   oldest first"; else echo "FAIL: order '$order'"; fail=1; fi
# Nothing but PINNED/NEW lines on stdout.
if printf '%s\n' "$out" | grep -qvE "^(PINNED|NEW)${tab}"; then echo "FAIL: stray stdout"; fail=1; else echo "OK:   stdout clean"; fi

refuses "gh failure names the query" "releases?per_page=100" GH_FAIL=1
refuses "npm failure names the package" "@anthropic-ai/claude-code" NPM_FAIL=1

exit "$fail"
