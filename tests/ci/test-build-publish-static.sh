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
# ---- five images: base, gis, bio, research, fetcher (in this order everywhere) ----
FIVE="spades-base spades-gis spades-bio spades-research spades-fetcher"
check "the name list is exactly the five images, in order" \
  bash -c '[ "$(sed -n "s/^names=(\(.*\))\$/\1/p" "$1")" = "$2" ]' _ "$BP" "$FIVE"
printf 'spades-base sha256:%s\nspades-gis sha256:%s\nspades-bio sha256:%s\nspades-research sha256:%s\n' "$D" "$D" "$D" "$D" > "$T/d4"
refuses "promote refuses a four-line file (the old four images)" 'bad digests file' "$BP" promote localhost:5000/x "$T/d4"
printf 'spades-base sha256:%s\nspades-gis sha256:%s\nspades-bio sha256:%s\nspades-fetcher sha256:%s\nspades-research sha256:%s\n' "$D" "$D" "$D" "$D" "$D" > "$T/d5ord"
refuses "promote refuses five lines with fetcher before research" 'bad digests file' "$BP" promote localhost:5000/x "$T/d5ord"
{ for n in $FIVE; do echo "$n sha256:$D"; done; echo "spades-extra sha256:$D"; } > "$T/d6"
refuses "promote refuses a sixth line" 'bad digests file' "$BP" promote localhost:5000/x "$T/d6"
check "build phase builds fetcher FROM base by the base digest from the build" \
  grep -qF 'build fetcher --build-arg "BASE_IMAGE=$registry/spades-base@$base_digest"' "$BP"
check "build phase smoke-tests all five images" \
  grep -qE '^[[:space:]]+for img in base gis bio research fetcher; do' "$BP"
check "build phase writes the five digests in order" \
  bash -c 'grep -A1 "printf .spades-base %s" "$1" | tr -d "\n" | grep -qF "spades-base %s\nspades-gis %s\nspades-bio %s\nspades-research %s\nspades-fetcher %s\n"' _ "$BP"
# The fetcher's smoke runs add the Chromium seccomp profile (sandbox ON) and nothing that weakens the container.
SECCOMP="$ROOT/project-template/config/fetcher-seccomp.json"
check "fetcher smoke runs pass the seccomp profile from project-template/config" \
  grep -qF -- '--security-opt "seccomp=$here/project-template/config/fetcher-seccomp.json"' "$BP"
check "the seccomp profile exists, is JSON, default-deny, and allows clone/setns/unshare unconditionally" \
  bash -c 'jq -e ".defaultAction == \"SCMP_ACT_ERRNO\" and ([\"clone\", \"setns\", \"unshare\"] - [.syscalls[] | select(.action == \"SCMP_ACT_ALLOW\" and ((.args // []) | length) == 0 and ((.includes // {}) | has(\"caps\") | not)) | .names[]] == [])" "$1" >/dev/null' _ "$SECCOMP"
check "build-publish.sh never weakens a container (privileged, unconfined, SYS_ADMIN, no-sandbox)" \
  bash -c '! grep -nE -- "--privileged|seccomp[=:]unconfined|SYS_ADMIN|no-sandbox|apparmor[=:]unconfined" "$1"' _ "$BP"
# publish.yml: one attest step per image, each paired with its own image's digest, all before promote.
WF="$ROOT/.github/workflows/publish.yml"
check "publish.yml build step exports a digest for each of the five images" \
  grep -qE '^[[:space:]]+for x in base gis bio research fetcher; do' "$WF"
for x in base gis bio research fetcher; do
  check "publish.yml attests spades-$x with steps.build.outputs.$x, before promote" bash -c '
    awk -v x="$2" "
      /- name: Attest spades-/ { cur = \$NF }
      cur == \"spades-\" x && /subject-name:/ { sn = (\$2 == \"ghcr.io/allenlarocque/spades-\" x) }
      cur == \"spades-\" x && /subject-digest:/ { sd = (\$0 ~ (\"\\\\$\\\\{\\\\{ steps\\\\.build\\\\.outputs\\\\.\" x \" \\\\}\\\\}\")) }
      /- name: Promote latest/ { if (!seen_attest) bad = 1; promote = 1 }
      /- name: Attest spades-/ { if (promote) bad = 1; if (\$NF == \"spades-\" x) seen_attest = 1 }
      END { exit !(sn && sd && seen_attest && promote && !bad) }" "$1"' _ "$WF" "$x"
done
check "publish.yml has exactly five attest steps, and one promote step after them" \
  bash -c '[ "$(grep -c "uses: actions/attest-build-provenance@v4" "$1")" = 5 ] && [ "$(grep -c "build-publish.sh promote" "$1")" = 1 ] \
    && [ "$(grep -n "build-publish.sh promote" "$1" | cut -d: -f1)" -gt "$(grep -n "attest-build-provenance" "$1" | tail -n1 | cut -d: -f1)" ]' _ "$WF"
[ "$fail" -eq 0 ] && echo "build-publish static: ALL PASSED" || { echo "build-publish static: FAILURES"; exit 1; }
