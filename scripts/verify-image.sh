#!/usr/bin/env bash
# Print the digest (sha256:<64 hex>) that ghcr.io/allenlarocque/<image>:latest points to, but only if a GitHub build-provenance attestation proves
# it was built by .github/workflows/publish.yml on main, is this image, comes from current main source, and is the newest build.
# Nothing on stdout on any failure; one message on stderr and an exit code that says why (see the table below). No flag or variable skips a check.
# Usage: verify-image.sh <image-name, e.g. spades-bio> <clone-dir>   (clone-dir: a git clone of this repo; its origin/main is fetched here)
#   2 bad arguments  10 gh missing / not logged in  11 registry or GitHub unreachable  12 no attestation / wrong workflow / wrong branch
#   13 attestation is for another image  14 stale (newest main not published yet)  15 not the newest build  16 clone not current
set -euo pipefail
PUBLISH_PATHS=(images scripts/build-publish.sh .github/workflows/publish.yml)   # keep equal to publish.yml's `paths` (a test compares them)
REPO=AllenLarocque/agent-containers
RUNS=https://github.com/AllenLarocque/agent-containers/actions/workflows/publish.yml
img=${1:-}; clone=${2:-}
die(){ echo "verify-image: ${img:-?}: $2" >&2; exit "$1"; }

# 1. arguments
[[ $# -eq 2 && $img =~ ^spades-[a-z]+$ ]] && git -C "$clone" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die 2 "usage: verify-image.sh spades-<name> <clone-of-agent-containers>"

# 2. gh installed and logged in
command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 \
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
errf=$(mktemp); trap 'rm -f "$errf"' EXIT
if ! lines=$(gh attestation verify "oci://ghcr.io/allenlarocque/$img@$digest" \
    -R "$REPO" --signer-workflow "$REPO/.github/workflows/publish.yml" --source-ref refs/heads/main --deny-self-hosted-runners \
    --format json --jq '.[] | .verificationResult | "\(.statement.subject[0].name) \(.statement.subject[0].digest.sha256) \(.signature.certificate.sourceRepositoryDigest) \(.signature.certificate.runInvocationURI | capture("/runs/(?<r>[0-9]+)/attempts/(?<a>[0-9]+)") | "\(.r) \(.a)")"' 2>"$errf"); then
  grep -Eq 'HTTP 5|HTTP 429|rate limit|dial tcp|timeout|no such host' "$errf" \
    && die 11 "could not reach GitHub to verify the attestation; try again, nothing was changed"
  die 12 "the image 'latest' points to was NOT built by publish on main; do not use it. Publish runs: $RUNS"
fi
[ -n "$lines" ] || die 12 "the image 'latest' points to was NOT built by publish on main; do not use it. Publish runs: $RUNS"

# 7. each attestation must pass, in order: image (13), source commit known (16), on main (12), contains newest publish change (14), newest run (15).
# The first failing check is that line's code; with several lines, the one that got furthest decides, so a stray attestation cannot hide the reason.
newest=$(git -C "$clone" log -1 --format=%H "$main" -- "${PUBLISH_PATHS[@]}")
pos(){ case $1 in 0) echo 0 ;; 13) echo 1 ;; 16) echo 2 ;; 12) echo 3 ;; 14) echo 4 ;; 15) echo 5 ;; esac; }
best=0
while read -r name hex sha run attempt _; do
  code=0
  if [ "$name" != "ghcr.io/allenlarocque/$img" ] || [ "sha256:$hex" != "$digest" ]; then code=13
  elif ! [[ $sha =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || ! git -C "$clone" cat-file -e "$sha^{commit}" 2>/dev/null; then code=16
  elif ! git -C "$clone" merge-base --is-ancestor "$sha" "$main" 2>/dev/null; then code=12
  elif [ -z "$newest" ] || ! git -C "$clone" merge-base --is-ancestor "$newest" "$sha" 2>/dev/null; then code=14
  elif [ "$run $attempt" != "$latest" ]; then code=15
  fi
  if [ "$code" -eq 0 ]; then printf '%s\n' "$digest"; exit 0; fi
  [ "$(pos "$code")" -le "$(pos "$best")" ] || best=$code
done <<<"$lines"

case $best in
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
  *)  die 12 "the image 'latest' points to was NOT built by publish on main; do not use it. Publish runs: $RUNS" ;;
esac
