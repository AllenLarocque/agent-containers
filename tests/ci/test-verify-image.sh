#!/usr/bin/env bash
# Tests for scripts/verify-image.sh with stub gh and curl on PATH (no network): one case per failure code, and the pass cases.
# Fixture: bare origin + clone; main = C1 (images/), C2 (README), C3 (scripts/build-publish.sh), C4 (README); side commit X; C5 (README) pushed later.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VI="$ROOT/scripts/verify-image.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"; cp "$ROOT/tests/launcher/stubs/gh" "$ROOT/tests/launcher/stubs/curl" "$T/bin/"
G=(git -c user.email=t@t -c user.name=t)
fail=0
ok(){ echo "OK:   $1"; }; bad(){ echo "FAIL: $1"; fail=1; }
check(){ if "${@:2}"; then ok "$1"; else bad "$1"; fi; }
refuses(){ if "${@:2}"; then bad "$1"; else ok "$1"; fi; }

# --- fixture ---
git init -q --bare -b main "$T/origin.git"
git clone -q "$T/origin.git" "$T/seed" 2>/dev/null; cd "$T/seed" || exit 1
git checkout -q -b main
commit(){ mkdir -p "$(dirname "$1")"; echo "$2" >> "$1"; git add "$1"; "${G[@]}" commit -q -m "$2"; git rev-parse HEAD; }
commit images/base/Dockerfile c1 >/dev/null; C2=$(commit README.md c2); C3=$(commit scripts/build-publish.sh c3); C4=$(commit README.md c4)
git push -q origin main
git clone -q "$T/origin.git" "$T/clone"; cd "$T/clone" || exit 1
git checkout -q -b side; X=$(commit README.md x); git checkout -q main
cd "$T/seed" || exit 1; C5=$(commit README.md c5)   # not pushed yet
cd "$ROOT" || exit 1
CL="$T/clone"
D="sha256:$(printf 'd%.0s' $(seq 64))"; DH=${D#sha256:}; E=$(printf 'e%.0s' $(seq 64))
N=ghcr.io/allenlarocque/spades-gis; NB=ghcr.io/allenlarocque/spades-base
A40=$(printf 'a%.0s' $(seq 40))
RUNS=https://github.com/AllenLarocque/agent-containers/actions/workflows/publish.yml
printf 'spades-gis latest %s\n' "$D" > "$T/reg"
: > "$T/log"

# attest <lines...>: write $GH_ATTEST from "name hex source run attempt" strings; latest <run attempt>
attest(){ : > "$T/attest"; local l; for l in "$@"; do echo "spades-gis $D $l" >> "$T/attest"; done; }
latest(){ echo "$1" > "$T/latest"; }
vi(){ PATH="$T/bin:$PATH" REG_TABLE="$T/reg" GH_ATTEST="$T/attest" GH_LATEST_RUN="$T/latest" GH_LOG="$T/log" "$VI" "$@"; }
# run: capture rc/out/err of the verify-image call; the seen-file is $SEEN if set, else a fresh path (no marks) per call
nseen=0
run(){ local s=${SEEN:-}; [ -n "$s" ] || { nseen=$((nseen + 1)); s="$T/seen.$nseen"; }
  out=$(vi spades-gis "$CL" "$s" 2>"$T/err"); rc=$?; err=$(<"$T/err"); }
# expect <name> <rc> [message fragment...]: the last run exited rc, printed nothing on failure, and said every fragment
expect(){
  local name=$1 want=$2 f; shift 2
  [ "$rc" = "$want" ] || { bad "$name (rc=$rc want $want: $err)"; return; }
  [ -z "$out" ] || { bad "$name (stdout not empty: $out)"; return; }
  for f in "$@"; do
    if [[ $f == "!"* ]]; then [[ $err != *"${f#!}"* ]] || { bad "$name (message has '${f#!}': $err)"; return; }
    else [[ $err == *"$f"* ]] || { bad "$name (message lacks '$f': $err)"; return; }; fi
  done
  [[ $err == "verify-image: spades-gis: "* ]] || { bad "$name (message prefix: $err)"; return; }
  ok "$name"
}
unset GH_NOAUTH GH_DOWN GH_RUNNING GH_BADHOST GH_ATTEST_DOWN GH_ATTEST_SAN GH_ATTEST_REF SEEN

attest "$N $DH $C3 77 1"; latest "77 1"
run; check "pass" test "$rc" = 0 -a "$out" = "$D"
check "exact flags" bash -c '
  l=$(grep "attestation verify" "$1"); for w in "-R AllenLarocque/agent-containers" "--signer-workflow AllenLarocque/agent-containers/.github/workflows/publish.yml" "--source-ref refs/heads/main" "--deny-self-hosted-runners" "oci://ghcr.io/allenlarocque/spades-gis@$2"; do [[ $l == *"$w"* ]] || exit 1; done; [[ $l != *":latest"* ]]' _ "$T/log" "$D"

attest "$N $DH $C4 77 1"; run; check "pass: source is a later commit" test "$rc" = 0 -a "$out" = "$D"

check "C5 unknown to the clone before the fetch" bash -c '! git -C "$1" cat-file -e "$2^{commit}" 2>/dev/null' _ "$CL" "$C5"
git -C "$T/seed" push -q origin main
attest "$N $DH $C5 77 1"; run; check "pass: source only reachable after fetch" test "$rc" = 0 -a "$out" = "$D"

attest "$N $DH $C2 77 1"; run; expect "stale" 14 "not published yet" "$RUNS" "!a publish run is in progress"
export GH_RUNNING=1; run; expect "stale, a run in progress" 14 "not published yet" "a publish run is in progress"; unset GH_RUNNING

attest "$N $DH $X 77 1"; run; expect "not on main" 12 "was NOT built by publish on main" "!not published yet"

attest "$N $DH $C3 70 1"; run; expect "not the newest build" 15 "points at an older build" "run publish on main"
attest "$N $DH $C3 77 1"; latest "77 2"; run; expect "newest run, older attempt" 15 "points at an older build"; latest "77 1"

attest "$NB $DH $C3 77 1"; run; expect "another image" 13 "points at a different image"
attest "$N $E $C3 77 1"; run; expect "subject digest differs" 13 "points at a different image"

attest; run; expect "no attestation" 12 "was NOT built by publish on main" "do not use it" "$RUNS"
expect "  ...and says to wait for a first attested publish" 12 "If this repo has not yet published this image with attestations" "wait for the publish run to finish"

attest "$N $DH $C3 70 1" "$N $DH $C3 77 1"; run; check "several attestations, one good" test "$rc" = 0 -a "$out" = "$D"
attest "$N $DH $C3 77 1" "$NB $DH $C3 77 1"; run; check "several attestations, good one last" test "$rc" = 0 -a "$out" = "$D"
attest "$NB $DH $C3 77 1" "$N $DH $C3 70 1"; run; expect "several, none good: furthest failure wins" 15 "points at an older build"

attest "$N $DH $A40 77 1"; run; expect "commit not in clone" 16 "could not bring origin/main up to date" "!NOT built"

attest "$N $DH $C3 77 1"
GH_DOWN=1 run; expect "GitHub down" 11 "could not reach" "nothing was changed" "!NOT built"
printf "spades-base latest %s\n" "$D" > "$T/reg.none"   # a table with no line for spades-gis
mv "$T/reg" "$T/reg.bak"; cp "$T/reg.none" "$T/reg"
run; expect "registry down" 11 "could not reach" "nothing was changed"
mv "$T/reg.bak" "$T/reg"

# gh attestation verify itself unreachable (gh api works): classified by stderr text, never as "NOT built"
for txt in "HTTP 503: Service Unavailable" "API rate limit exceeded" "dial tcp: lookup api.github.com: no such host" \
           "failed to update trust root: TUF metadata could not be fetched" \
           "tuf: failed to download timestamp.json" \
           "failed to create sigstore verifier: could not load the trusted root" \
           "Get \"https://tuf-repo-cdn.sigstore.dev/root.json\": net/http: TLS handshake failure" \
           "Post \"https://api.github.com/graphql\": connect: connection refused" \
           "read tcp 10.0.0.2:51234->140.82.112.6:443: read: connection reset by peer" \
           "read tcp 10.0.0.2:51234->140.82.112.6:443: i/o timeout" \
           "Get \"https://api.github.com/repos/x/attestations\": EOF"; do
  GH_ATTEST_DOWN=$txt run; expect "attestation lookup unreachable: $txt" 11 "could not reach" "nothing was changed" "!NOT built"
done
GH_ATTEST_DOWN="HTTP 404: Not Found" run; expect "attestation lookup failing otherwise is 'NOT built'" 12 "was NOT built by publish on main"
expect "  ...with the first-publish hint" 12 "wait for the publish run to finish"
# verdicts stay 12 even when they name Sigstore (the words tuf/sigstore alone must not turn a failed verification into 'unreachable')
for txt in "Error: no attestations found for subject" \
           "Error: verifying with issuer \"sigstore.dev\": failed to verify certificate identity" \
           "verification failed: expected SourceRepositoryRef to be refs/heads/main, got refs/heads/evil" \
           "failed to verify sigstore bundle: no matching certificate identity"; do
  GH_ATTEST_DOWN=$txt run; expect "verification verdict is 'NOT built', not unreachable: $txt" 12 "was NOT built by publish on main" "!could not reach"
done

# malformed lines never pass: surplus tokens, missing tokens, null / option-like source sha
attest "$N $DH $C3 77 1 EXTRA junk"; run; expect "extra trailing fields" 13 "points at a different image"
attest "$N $DH $C3 77"; run; expect "too few fields" 13 "points at a different image"
attest "$N ${DH}0 $C3 77 1"; run; expect "subject digest not 64 hex" 13 "points at a different image"
for s in null -x --all; do
  : > "$T/log"; attest "$N $DH $s 77 1"; run; expect "malformed source sha '$s'" 12 "was NOT built by publish on main" "!could not bring"
  ! grep -q -e "$s" <(grep -v 'attestation verify' "$T/log") && ok "malformed source sha '$s' is never handed to gh" || bad "sha '$s' leaked into a call"
done

# signer workflow and ref are re-checked per attestation, not trusted to gh
attest "$N $DH $C3 77 1"
GH_ATTEST_SAN="https://github.com/AllenLarocque/agent-containers/.github/workflows/ci.yml@refs/heads/main" run
expect "signer is another workflow file" 12 "was NOT built by publish on main" "!wait for the publish run"
GH_ATTEST_SAN="https://github.com/AllenLarocque/agent-containers/.github/workflows/publish.yml@refs/heads/evil" run
expect "signer identity at another ref" 12 "was NOT built by publish on main"
GH_ATTEST_REF=refs/heads/evil run; expect "certificate source ref is not main" 12 "was NOT built by publish on main"
GH_ATTEST_SAN=null run; expect "signer identity missing" 12 "was NOT built by publish on main"
attest "$N $DH $C3 70 1" "$N $DH $C3 77 1"; GH_ATTEST_REF=refs/heads/evil run; expect "bad ref on every line beats older-build" 12 "was NOT built by publish on main"
attest "$N $DH $C3 77 1"

# an empty clone argument is not "the current directory"
out=$(vi spades-gis '' "$T/seen.x" 2>"$T/err"); rc=$?; err=$(<"$T/err")
{ [ "$rc" = 2 ] && [ -z "$out" ] && [[ $err == *usage* ]]; } && ok "empty clone argument" || bad "empty clone argument (rc=$rc: $err)"
# the seen-file argument is required
out=$(vi spades-gis "$CL" 2>"$T/err"); rc=$?; err=$(<"$T/err")
{ [ "$rc" = 2 ] && [ -z "$out" ] && [[ $err == *usage* ]]; } && ok "missing seen-file argument" || bad "missing seen-file argument (rc=$rc: $err)"
out=$(vi spades-gis "$CL" '' 2>"$T/err"); rc=$?; err=$(<"$T/err")
{ [ "$rc" = 2 ] && [ -z "$out" ] && [[ $err == *usage* ]]; } && ok "empty seen-file argument" || bad "empty seen-file argument (rc=$rc: $err)"

GH_NOAUTH=1 run; expect "not logged in" 10 "gh auth login"
GH_BADHOST=1 run; check "a bad token for another gh host does not count: only github.com is checked" test "$rc" = 0 -a "$out" = "$D"
mkdir -p "$T/nogh"; cp "$ROOT/tests/launcher/stubs/curl" "$T/nogh/curl"; ln -s "$(command -v git)" "$T/nogh/git"; ln -s "$(command -v dirname)" "$T/nogh/dirname"
out=$(PATH="$T/nogh" REG_TABLE="$T/reg" GH_ATTEST="$T/attest" GH_LATEST_RUN="$T/latest" "$(command -v bash)" "$VI" spades-gis "$CL" "$T/seen.nogh" 2>"$T/err"); rc=$?; err=$(<"$T/err")
expect "gh missing" 10 "gh auth login"

out=$(vi 'spades-gis;id' "$CL" "$T/seen.x" 2>"$T/err"); rc=$?; err=$(<"$T/err")
{ [ "$rc" = 2 ] && [ -z "$out" ] && [[ $err == *usage* ]]; } && ok "bad image name" || bad "bad image name (rc=$rc: $err)"
out=$(vi spades-gis "$T/not-a-clone" "$T/seen.x" 2>"$T/err"); rc=$?; err=$(<"$T/err")
{ [ "$rc" = 2 ] && [ -z "$out" ] && [[ $err == *usage* ]]; } && ok "clone is not a git work tree" || bad "not a clone (rc=$rc: $err)"
out=$(vi 2>"$T/err"); rc=$?; err=$(<"$T/err")
{ [ "$rc" = 2 ] && [ -z "$out" ] && [[ $err == *usage* ]]; } && ok "no arguments" || bad "no arguments (rc=$rc: $err)"

# --- high-water mark: the seen-file records the newest (run, attempt) accepted per image; an older attested build is refused even when
# GitHub's run list says it is the newest (re-runs cancelled / newer runs deleted by someone with Write access)
OLDER="points at an older build than one this host has already accepted"
M="$T/marks/images.seen"; mkdir -p "$T/marks"
attest "$N $DH $C3 77 1"; latest "77 1"
SEEN=$M run; check "mark: no seen-file yet -> pass" test "$rc" = 0 -a "$out" = "$D"
check "  ...the seen-file now holds 'spades-gis 77 1', mode 600" test "$(cat "$M")|$(stat -c %a "$M")" = "spades-gis 77 1|600"
check "  ...no temp file left beside it" test "$(find "$T/marks" -mindepth 1 | wc -l)" -eq 1
SEEN=$M run; check "mark 77 1, attestation 77 1 -> pass (idempotent), mark unchanged" test "$rc" = 0 -a "$out" = "$D" -a "$(cat "$M")" = "spades-gis 77 1"
echo "spades-gis 80 1" > "$M"; cp "$M" "$T/m.before"
SEEN=$M run; expect "mark 80 1, attestation and newest run 77 1 (run list manipulated) -> refused" 15 "$OLDER" "points at an older build" "run publish on main" "$M"
check "  ...mark unchanged" cmp -s "$M" "$T/m.before"
echo "spades-gis 77 1" > "$M"; attest "$N $DH $C3 77 2"; latest "77 2"
SEEN=$M run; check "mark 77 1, attestation and newest 77 2 -> pass, mark becomes 77 2" test "$rc" = 0 -a "$out" = "$D" -a "$(cat "$M")" = "spades-gis 77 2"
attest "$N $DH $C3 77 1"; latest "77 1"
SEEN=$M run; expect "mark 77 2, attestation and newest 77 1 (older attempt) -> refused" 15 "$OLDER"
check "  ...mark unchanged" test "$(cat "$M")" = "spades-gis 77 2"
echo "spades-gis 9 1" > "$M"
SEEN=$M run; check "mark 9 1, attestation 77 1 -> pass (run ids compare as numbers, not text)" test "$rc" = 0 -a "$(cat "$M")" = "spades-gis 77 1"
echo "spades-gis 76 5" > "$M"
SEEN=$M run; check "mark 76 5, attestation 77 1 -> pass (run id decides before attempt)" test "$rc" = 0 -a "$(cat "$M")" = "spades-gis 77 1"
printf 'spades-base 99 3\nspades-bio 1 1\n' > "$M"
SEEN=$M run; check "a mark for another image does not affect this one" test "$rc" = 0 -a "$out" = "$D"
check "  ...and is kept when this image's mark is written" test "$(sort "$M" | tr '\n' ' ')" = "spades-base 99 3 spades-bio 1 1 spades-gis 77 1 "
attest "$N $DH $C3 70 1" "$N $DH $C3 77 1"; echo "spades-gis 80 1" > "$M"
SEEN=$M run; expect "several attestations, furthest failure is the mark -> its message" 15 "$OLDER"
attest "$N $DH $C3 77 1"
for bad in "spades-gis 77" "spades-gis 77 1 x" "spades-gis 77 1; touch $T/pwned" "spades-gis \$((7*11)) 1" "garbage" "" "spades-gis 77 1|spades-gis 78 1"; do
  printf '%s\n' "$bad" | tr '|' '\n' > "$M"; cp "$M" "$T/m.before"
  SEEN=$M run; expect "malformed seen-file '$bad' -> refused, names the file" 2 "seen-file $M" "malformed"
  check "  ...file left as it was" cmp -s "$M" "$T/m.before"
done
check "  ...nothing in the seen-file was ever executed" test ! -e "$T/pwned"
mkdir -p "$T/marks/adir"; SEEN="$T/marks/adir" run; expect "seen-file is a directory -> refused" 2 "seen-file $T/marks/adir"
if [ "$(id -u)" -ne 0 ]; then
  mkdir -p "$T/ro"; chmod 500 "$T/ro"
  SEEN="$T/ro/images.seen" run
  if [ "$rc" -ne 0 ] && [ -z "$out" ] && [[ $err == *"could not be written"* ]] && [ ! -e "$T/ro/images.seen" ]; then ok "unwritable seen-file location -> no digest, says so"
  else bad "unwritable seen-file location (rc=$rc out=$out: $err)"; fi
  printf 'spades-gis 1 1\n' > "$T/ro2.seen"; mkdir -p "$T/ro2"; mv "$T/ro2.seen" "$T/ro2/images.seen"; chmod 500 "$T/ro2"
  SEEN="$T/ro2/images.seen" run
  if [ "$rc" -ne 0 ] && [ -z "$out" ] && [[ $err == *"could not be written"* ]] && [ "$(cat "$T/ro2/images.seen")" = "spades-gis 1 1" ]; then ok "existing seen-file in an unwritable directory -> no digest, mark unchanged"
  else bad "existing seen-file in an unwritable directory (rc=$rc out=$out: $err)"; fi
  chmod 700 "$T/ro" "$T/ro2"
fi

git -C "$CL" remote set-url origin "$T/nope.git"
run; expect "fetch fails" 16 "could not bring origin/main up to date"
git -C "$CL" remote set-url origin "$T/origin.git"

[ "$fail" -eq 0 ] && echo "verify-image: ALL PASSED" || { echo "verify-image: FAILURES"; exit 1; }
