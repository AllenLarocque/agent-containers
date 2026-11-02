#!/usr/bin/env bash
# Tests for scripts/registry-digest.sh with a stub curl on PATH (no network): good token + header -> the digest;
# HTTP failure, a missing/garbled header and bad arguments -> non-zero with a message on stderr.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RD="$ROOT/scripts/registry-digest.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"; cp "$ROOT/tests/launcher/stubs/curl" "$T/bin/curl"
D1=$(printf 'a%.0s' $(seq 64)); D2=$(printf 'b%.0s' $(seq 64))
printf 'spades-bio latest sha256:%s\nspades-bio 2026.10.30-8299ac4 sha256:%s\nspades-gis latest FAIL\nspades-base latest sha256:short\n' "$D1" "$D2" > "$T/table"
export REG_TABLE="$T/table" PATH="$T/bin:$PATH"
fail=0
ok(){ echo "OK:   $1"; }; bad(){ echo "FAIL: $1"; fail=1; }
out=$("$RD" spades-bio 2>/dev/null) && [ "$out" = "sha256:$D1" ] && ok "latest -> its digest" || bad "latest -> its digest ($out)"
out=$("$RD" spades-bio 2026.10.30-8299ac4 2>/dev/null) && [ "$out" = "sha256:$D2" ] && ok "explicit tag" || bad "explicit tag ($out)"
err=$("$RD" spades-gis 2>&1 >/dev/null); rc=$?
{ [ "$rc" -ne 0 ] && grep -q 'registry-digest:' <<<"$err"; } && ok "HTTP failure -> non-zero + message" || bad "HTTP failure (rc=$rc: $err)"
err=$("$RD" spades-research 2>&1 >/dev/null); rc=$?
{ [ "$rc" -ne 0 ] && grep -q 'registry-digest:' <<<"$err"; } && ok "unknown image/tag -> non-zero" || bad "unknown image (rc=$rc: $err)"
err=$("$RD" spades-base 2>&1 >/dev/null); rc=$?
{ [ "$rc" -ne 0 ] && grep -q 'bad or missing Docker-Content-Digest' <<<"$err"; } && ok "malformed digest header -> non-zero" || bad "malformed digest (rc=$rc: $err)"
err=$(REG_TOKEN_FAIL=1 "$RD" spades-bio 2>&1 >/dev/null); rc=$?
{ [ "$rc" -ne 0 ] && grep -q 'pull token' <<<"$err"; } && ok "token failure -> non-zero" || bad "token failure (rc=$rc: $err)"
out=$(REG_STDERR_NOISE=1 "$RD" spades-bio 2>/dev/null) && [ "$out" = "sha256:$D1" ] && ok "stderr noise stays off stdout" || bad "stderr noise ($out)"
for a in 'evil' 'spades-' 'spades-Bio' 'spades-bio/../x' 'spades-bio;id' ''; do
  "$RD" "$a" >/dev/null 2>&1 && bad "bad image name '$a' accepted" || ok "bad image name '$a' refused"
done
for t in 'a b' '-x' 'a/b' 'a;b' '$(id)'; do
  "$RD" spades-bio "$t" >/dev/null 2>&1 && bad "bad tag '$t' accepted" || ok "bad tag '$t' refused"
done
[ "$fail" -eq 0 ] && echo "registry-digest: ALL PASSED" || { echo "registry-digest: FAILURES"; exit 1; }
