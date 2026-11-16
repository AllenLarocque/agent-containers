#!/usr/bin/env bash
# Static checks on scripts/build-publish.sh (no Docker): the build phase takes every digest from buildx's
# --metadata-file and never from a tag; only promote() reads a tag back; argument validation runs before any docker call.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BP="$ROOT/scripts/build-publish.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0
ok(){ echo "OK:   $1"; }; bad(){ echo "FAIL: $1"; fail=1; }
check(){ if "${@:2}"; then ok "$1"; else bad "$1"; fi; }
# refuses <desc> <stderr-pattern> <cmd...>: exits non-zero and says the pattern on stderr
refuses(){ local err rc=0; err=$("${@:3}" 2>&1 >/dev/null) || rc=$?
  if [ "$rc" -ne 0 ] && grep -qi -- "$2" <<<"$err"; then ok "$1"; else bad "$1 (rc=$rc: $err)"; fi; }
# the script with the promote() function body removed
outside_promote(){ awk '/^promote\(\)/{p=1} !p{print} p&&/^}/{p=0}' "$BP"; }

check "no digest is read from a tag in the build phase" \
  bash -c '! grep -nE "imagetools inspect|digest_of" <<<"$1"' _ "$(outside_promote)"
check "every build takes its digest from --metadata-file" \
  bash -c 'grep -q -- "--metadata-file" "$1" && grep -q "containerimage.digest" "$1"' _ "$BP"
# (the old table-rendering flow is gone; names are assembled so this file does not itself match)
old1="render-""digests"; old2="digests""\\.md"
check "the old digests table flow is gone" \
  bash -c '! grep -qE "$3|$4" "$1" && [ ! -e "$2/scripts/$3.sh" ] && [ ! -e "$2/tests/ci/test-$3.sh" ]' _ "$BP" "$ROOT" "$old1" "$old2"
# the body of build_phase(), up to its first build/docker call
build_phase_head(){ awk '/^build_phase\(\)/{p=1; next} p&&/^[[:space:]]+(build base|docker )/{exit} p{print}' "$BP"; }
check "the build phase removes a stale digests file before its first build/docker call" \
  bash -c 'grep -qF "rm -f \"\$out\"" <<<"$1"' _ "$(build_phase_head)"
check "latest is touched only inside promote()" \
  bash -c '! grep -n ":latest" <<<"$1"' _ "$(outside_promote)"
refuses "unknown phase prints usage" 'usage' "$BP" nope
printf 'spades-base nope\n' > "$T/d"
refuses "promote refuses a malformed digests file" 'bad digests file' "$BP" promote localhost:5000/x "$T/d"
D=$(printf 'a%.0s' $(seq 64))
printf 'spades-base sha256:%s\nspades-gis sha256:%s\nspades-bio sha256:%s\n' "$D" "$D" "$D" > "$T/d3"
refuses "promote refuses a file with fewer than four lines" 'bad digests file' "$BP" promote localhost:5000/x "$T/d3"
printf 'spades-base sha256:%s\nspades-bio sha256:%s\nspades-gis sha256:%s\nspades-research sha256:%s\n' "$D" "$D" "$D" "$D" > "$T/dord"
refuses "promote refuses lines out of order" 'bad digests file' "$BP" promote localhost:5000/x "$T/dord"
[ "$fail" -eq 0 ] && echo "build-publish static: ALL PASSED" || { echo "build-publish static: FAILURES"; exit 1; }
