#!/usr/bin/env bash
# Tests for scripts/ci-classify.sh: which change sets may skip the image build. A wrong "docs"
# would let an untested image change through, so every skip path is pinned here.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CL="$ROOT/scripts/ci-classify.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0
git -C "$T" init -q -b main
# Every commit starts `git maintenance run --auto`, detached on newer git: it can still be writing
# .git/objects when the EXIT trap's rm -rf runs ("Directory not empty").
git -C "$T" config maintenance.auto false
git -C "$T" config gc.auto 0
git -C "$T" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
base=$(git -C "$T" rev-parse HEAD)

# expect <want> <event> <branch> <draft> <file>...  (commits the files on a fresh branch off base)
expect() {
  local want=$1 event=$2 branch=$3 draft=$4 got; shift 4
  git -C "$T" checkout -q -B "$branch" "$base"
  for f in "$@"; do mkdir -p "$T/$(dirname "$f")"; echo "$RANDOM" > "$T/$f"; git -C "$T" add "$f"; done
  git -C "$T" -c user.name=t -c user.email=t@t commit -q --allow-empty -m change
  got=$(cd "$T" && bash "$CL" "$event" "$base" HEAD "$branch" "$draft" 2>/dev/null)
  if [ "$got" = "$want" ]; then echo "OK:   $want <- $event $branch draft=$draft: $*"
  else echo "FAIL: want $want, got $got <- $event $branch draft=$draft: $*"; fail=1; fi
}
PR=pull_request; WD=workflow_dispatch
expect docs    $PR feat/x    false README.md docs/a/b.png project-template/README.md
expect docs    $PR feat/x    true  docs/runbooks/x.md
expect full    $WD feat/x    false README.md               # dispatch stays full
expect full    $PR feat/x    false README.md images/base/NOTES.md   # a Dockerfile could COPY it
expect full    $PR feat/x    false tests/smoke/README.md
expect full    $PR feat/x    false README.md bin/agent-up
expect full    $PR feat/x    false                         # empty diff proves nothing
expect draft   $PR feat/x    true  scripts/x.sh
expect full    $PR feat/x    false scripts/x.sh
expect full    push main     false README.md
[ "$fail" -eq 0 ] && echo "ci-classify: ALL PASSED" || { echo "ci-classify: FAILURES"; exit 1; }
