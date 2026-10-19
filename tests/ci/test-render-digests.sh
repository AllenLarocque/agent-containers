#!/usr/bin/env bash
# Tests for scripts/render-digests.sh: the digests.md skeleton stays unchanged, there is one row per
# image (base, gis, bio, research; research last), and a missing digest argument is an error.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RD="$ROOT/scripts/render-digests.sh"
fail=0
ok()  { echo "OK:   $1"; }
bad() { echo "FAIL: $1"; fail=1; }

h() { printf 'sha256:%064d' 0 | tr 0 "$1"; }
out=$(bash "$RD" 2000.01.01-dryrun "$(h a)" "$(h b)" "$(h c)" "$(h e)" 2>&1) || out=""

if [ "$(printf '%s\n' "$out" | head -7)" = "$(head -7 "$ROOT/digests.md")" ]; then ok "skeleton (first 7 lines) unchanged"
else bad "skeleton (first 7 lines) differs from digests.md"; fi

n=$(printf '%s\n' "$out" | grep -c '^| spades-' || true)
if [ "$n" = 4 ]; then ok "exactly 4 image rows"; else bad "expected 4 image rows, got $n"; fi

want="| spades-research | 2000.01.01-dryrun | \`$(h e)\` |"
if printf '%s\n' "$out" | grep -qxF -- "$want"; then ok "research row present"; else bad "research row missing: $want"; fi
last=$(printf '%s\n' "$out" | grep '^| spades-' | tail -n 1)
if [ "$last" = "$want" ]; then ok "research row is the last row"; else bad "last row is '$last'"; fi

if bash "$RD" 2000.01.01-dryrun "$(h a)" "$(h b)" "$(h c)" >/dev/null 2>&1; then bad "missing research digest accepted (research digest must be required)"
else ok "missing research digest rejected"; fi

exit "$fail"
