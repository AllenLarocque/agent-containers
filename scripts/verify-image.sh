#!/usr/bin/env bash
# Print the digest (sha256:<64 hex>) that ghcr.io/allenlarocque/<image>:latest points to, but only if a GitHub build-provenance attestation proves
# it was built by .github/workflows/publish.yml on main, is this image, comes from current main source, is the newest build, and is not older than
# a build this host has already accepted (the high-water mark in <seen-file>).
# Nothing on stdout on any failure; one message on stderr and an exit code that says why (see the table below). No flag or variable skips a check.
# Usage: verify-image.sh <image-name, e.g. spades-bio> <clone-dir> <seen-file>
#   clone-dir: a git clone of this repo; its origin/main is fetched here.
#   seen-file: the caller's state file, one line per image: "<image-name> <run-id> <attempt>" (the newest publish run accepted for it).
#              Missing = no marks yet. Rewritten (atomically, mode 600) whenever a digest is printed; a digest is never printed unless it was.
#   2 bad arguments or a malformed seen-file  10 gh missing / not logged in  11 registry or GitHub unreachable
#   12 no attestation / wrong workflow / wrong branch  13 attestation is for another image  14 stale (newest main not published yet)
#   15 not the newest build, or older than a build this host already accepted  16 clone not current  17 seen-file could not be written
set -euo pipefail
PUBLISH_PATHS=(images scripts/build-publish.sh .github/workflows/publish.yml)   # keep equal to publish.yml's `paths` (a test compares them)
REPO=AllenLarocque/agent-containers
RUNS=https://github.com/AllenLarocque/agent-containers/actions/workflows/publish.yml
img=${1:-}; clone=${2:-}; seen=${3:-}
die(){ echo "verify-image: ${img:-?}: $2" >&2; exit "$1"; }

# 1. arguments
[[ $# -eq 3 && $img =~ ^spades-[a-z]+$ && -n $clone && -n $seen ]] && git -C "$clone" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die 2 "usage: verify-image.sh spades-<name> <clone-of-agent-containers> <seen-file>"

# 1b. the high-water marks: every line must be "spades-<name> <run-id> <attempt>", one per image; anything else is corruption, never "no mark"
seen_lines=(); mark_run=""; mark_att=""
if [ -e "$seen" ] || [ -L "$seen" ]; then
  { [ -f "$seen" ] && [ -r "$seen" ]; } || die 2 "the seen-file $seen is not a readable file; fix or remove it, then run again"
  while IFS= read -r l || [ -n "$l" ]; do
    [[ $l =~ ^spades-[a-z]+\ [0-9]+\ [0-9]+$ ]] || die 2 "the seen-file $seen is malformed (expected lines '<image> <run-id> <attempt>'); fix it, then run again"
    n=${l%% *}
    for s in ${seen_lines[@]+"${seen_lines[@]}"}; do
      [ "${s%% *}" != "$n" ] || die 2 "the seen-file $seen is malformed ($n appears twice); fix it, then run again"
    done
    seen_lines+=("$l")
    if [ "$n" = "$img" ]; then r=${l#* }; mark_run=${r%% *}; mark_att=${r#* }; fi
  done <"$seen"
fi

# 2. gh installed and logged in to github.com (a bad token for another host must not count)
command -v gh >/dev/null 2>&1 && gh auth status --hostname github.com >/dev/null 2>&1 \
  || die 10 "gh is missing or not logged in; run 'gh auth login' on the host"

# 3. current origin/main (FETCH_HEAD from here on)
GIT_TERMINAL_PROMPT=0 git -C "$clone" fetch -q origin main >/dev/null 2>&1 && main=$(git -C "$clone" rev-parse -q --verify 'FETCH_HEAD^{commit}') \
  || die 16 "could not bring origin/main up to date in $clone; fix the clone or the network, then run again"

# 4. the digest latest points to
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
digest=$("$here/registry-digest.sh" "$img" 2>/dev/null) && [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] \
  || die 11 "could not reach the registry (ghcr.io); try again, nothing was changed"

# 5. the newest successful publish run on main
latest=$(gh api -X GET "repos/$REPO/actions/workflows/publish.yml/runs" -f branch=main -f status=success -f per_page=1 \
  --jq '.workflow_runs[0] | "\(.id) \(.run_attempt)"' 2>/dev/null) && [ -n "$latest" ] && [ "$latest" != "null null" ] \
  || die 11 "could not reach GitHub to find the newest publish run; try again, nothing was changed"

# 6. the attestations for exactly this digest
errf=$(mktemp); tmpm=""; trap 'rm -f "$errf"; [ -z "$tmpm" ] || rm -f "$tmpm"' EXIT
NOTMAIN="the image 'latest' points to was NOT built by publish on main; do not use it."
FIRST="If this repo has not yet published this image with attestations (first publish after the change, or a new image), wait for the publish run to finish."
if ! lines=$(gh attestation verify "oci://ghcr.io/allenlarocque/$img@$digest" \
    -R "$REPO" --signer-workflow "$REPO/.github/workflows/publish.yml" --source-ref refs/heads/main --deny-self-hosted-runners \
    --format json --jq '.[] | .verificationResult | "\(.statement.subject[0].name) \(.statement.subject[0].digest.sha256) \(.signature.certificate.sourceRepositoryDigest) \(.signature.certificate.runInvocationURI | capture("/runs/(?<r>[0-9]+)/attempts/(?<a>[0-9]+)") | "\(.r) \(.a)") \(.signature.certificate.subjectAlternativeName) \(.signature.certificate.sourceRepositoryRef)"' 2>"$errf"); then
  # Unreachable (11), not "NOT built" (12): transport errors always; a Sigstore trust-root (TUF) or sigstore error only when gh did not
  # say that verification itself failed (its verdicts name the issuer, e.g. 'verifying with issuer "sigstore.dev"').
  if grep -Eqi 'HTTP 5[0-9][0-9]|HTTP 429|rate limit|dial tcp|timeout|timed out|no such host|TLS handshake|connection refused|connection reset' "$errf" \
     || grep -Eq '(^|[^A-Za-z])EOF([^A-Za-z]|$)' "$errf" \
     || { grep -Eqi '(^|[^a-z])tuf([^a-z]|$)|sigstore' "$errf" \
          && ! grep -Eqi 'no attestations|no matching|verification failed|failed to verify|verifying with issuer|expected .* got|does not match|mismatch' "$errf"; }; then
    die 11 "could not reach GitHub or Sigstore to verify the attestation; try again, nothing was changed"
  fi
  die 12 "$NOTMAIN $FIRST Publish runs: $RUNS"
fi
[ -n "$lines" ] || die 12 "$NOTMAIN $FIRST Publish runs: $RUNS"

# numcmp <a> <b> (digit strings, already validated): prints lt, eq or gt. No arithmetic, so no overflow and nothing is evaluated.
numcmp(){
  local a=$1 b=$2
  while [[ $a == 0?* ]]; do a=${a#0}; done
  while [[ $b == 0?* ]]; do b=${b#0}; done
  if [ "${#a}" -ne "${#b}" ]; then [ "${#a}" -lt "${#b}" ] && echo lt || echo gt
  elif [ "$a" = "$b" ]; then echo eq
  elif [[ $a < $b ]]; then echo lt
  else echo gt; fi
}
# older_than_mark <run> <attempt>: true when (run, attempt) is below this image's mark (run id first, then attempt)
older_than_mark(){
  [ -n "$mark_run" ] || return 1
  case $(numcmp "$1" "$mark_run") in
    lt) return 0 ;; gt) return 1 ;;
    *) [ "$(numcmp "$2" "$mark_att")" = lt ] ;;
  esac
}
# record_mark <run> <attempt>: rewrite the seen-file with this image's new mark, other images' lines kept (temp file + mv, mode 600)
record_mark(){
  local dir l
  dir=$(dirname "$seen")
  tmpm=$(mktemp "$dir/.images.seen.XXXXXX" 2>/dev/null) || return 1
  {
    for l in ${seen_lines[@]+"${seen_lines[@]}"}; do [ "${l%% *}" = "$img" ] || printf '%s\n' "$l"; done
    printf '%s %s %s\n' "$img" "$1" "$2"
  } >"$tmpm" && chmod 600 "$tmpm" && mv -f "$tmpm" "$seen" || return 1
  tmpm=""
}

# 7. each attestation must pass, in this order of stages (the first failing stage is that line's code):
#   1 shape: exactly 7 fields, subject name and digest are this image (13)
#   2 signer workflow and ref re-checked here, not trusted to gh (12; also a source sha that is not hex)
#   3 source commit is in the clone (16)   4 it is an ancestor of origin/main (12)
#   5 it contains the newest publish-path change (14)   6 it is the newest run and attempt (15)
#   7 it is not older than the run this host already accepted for this image (15)
# With several lines, the one that got furthest decides, so a stray attestation cannot hide the real reason.
SAN="https://github.com/$REPO/.github/workflows/publish.yml@refs/heads/main"
newest=$(git -C "$clone" log -1 --format=%H "$main" -- "${PUBLISH_PATHS[@]}")
best=0; bestcode=12
while read -r line; do
  read -r -a f <<<"$line"
  stage=0; code=0
  if [ "${#f[@]}" -ne 7 ] || [ "${f[0]}" != "ghcr.io/allenlarocque/$img" ] || [ "sha256:${f[1]}" != "$digest" ] \
     || ! [[ ${f[1]} =~ ^[0-9a-f]{64}$ ]]; then stage=1; code=13
  elif [ "${f[5]}" != "$SAN" ] || [ "${f[6]}" != "refs/heads/main" ]; then stage=2; code=12
  elif ! [[ ${f[2]} =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then stage=3; code=12
  elif ! git -C "$clone" cat-file -e "${f[2]}^{commit}" 2>/dev/null; then stage=3; code=16
  elif ! git -C "$clone" merge-base --is-ancestor "${f[2]}" "$main" 2>/dev/null; then stage=4; code=12
  elif [ -z "$newest" ] || ! git -C "$clone" merge-base --is-ancestor "$newest" "${f[2]}" 2>/dev/null; then stage=5; code=14
  elif ! [[ ${f[3]} =~ ^[0-9]+$ && ${f[4]} =~ ^[0-9]+$ ]] || [ "${f[3]} ${f[4]}" != "$latest" ]; then stage=6; code=15
  elif older_than_mark "${f[3]}" "${f[4]}"; then stage=7; code=15
  fi
  if [ "$code" -eq 0 ]; then
    record_mark "${f[3]}" "${f[4]}" || die 17 "the seen-file $seen could not be written; no digest given. Fix its directory, then run again"
    printf '%s\n' "$digest"; exit 0
  fi
  if [ "$stage" -gt "$best" ]; then best=$stage; bestcode=$code; fi
done <<<"$lines"

case $best in
  7) die 15 "'latest' points at an older build than one this host has already accepted (run $mark_run attempt $mark_att); do not use it. To restore it, run publish on main (to accept the older build on purpose, delete the $img line from $seen). Publish runs: $RUNS" ;;
esac
case $bestcode in
  13) die 13 "'latest' for this image points at a different image; do not use it" ;;
  16) die 16 "could not bring origin/main up to date (the attested source commit is not in $clone); fix the clone or the network, then run again" ;;
  14) # 8. say so when a publish is running (a failed lookup adds nothing)
      running=""
      for st in in_progress queued; do
        c=$(gh api -X GET "repos/$REPO/actions/workflows/publish.yml/runs" -f branch=main -f "status=$st" -f per_page=1 --jq '.total_count' 2>/dev/null) || c=0
        [[ $c =~ ^[0-9]+$ && $c -gt 0 ]] && running=" (a publish run is in progress)"
      done
      die 14 "images for the newest main are not published yet$running; see $RUNS" ;;
  15) die 15 "'latest' points at an older build; run publish on main to restore it. Publish runs: $RUNS" ;;
  *)  die 12 "$NOTMAIN Publish runs: $RUNS" ;;
esac
