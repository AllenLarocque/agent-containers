#!/usr/bin/env bash
# publish.yml's push `paths` must equal PUBLISH_PATHS in scripts/verify-image.sh (modulo a trailing /**):
# verify-image.sh asks "did publish run for the newest commit touching these paths?", so drift would
# make it trust (or distrust) the wrong commits.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
ok(){ echo "OK:   $1"; }; bad(){ echo "FAIL: $1"; fail=1; }
check(){ if "${@:2}"; then ok "$1"; else bad "$1"; fi; }
wf=$(grep -m1 -E '^[[:space:]]+paths:' "$ROOT/.github/workflows/publish.yml" | sed -E 's/^[^[]*\[//; s/\].*$//' \
  | tr ',' '\n' | tr -d ' "' | sed 's#/\*\*$##' | sort)
vi=$(grep -m1 '^PUBLISH_PATHS=(' "$ROOT/scripts/verify-image.sh" | sed -E 's/^PUBLISH_PATHS=\(//; s/\).*$//' \
  | tr ' ' '\n' | grep -v '^$' | sort)
[ -n "$wf" ] && [ -n "$vi" ] && ok "both path lists were extracted" || bad "could not extract a path list (publish.yml: '$wf'; verify-image.sh: '$vi')"
check "publish.yml paths == verify-image.sh PUBLISH_PATHS" diff <(printf '%s\n' "$wf") <(printf '%s\n' "$vi")
[ "$fail" -eq 0 ] && echo "publish-paths: ALL PASSED" || { echo "publish-paths: FAILURES"; exit 1; }
