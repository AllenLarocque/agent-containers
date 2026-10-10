#!/usr/bin/env bash
# Decide how much of CI a run needs. Prints ONE word on stdout:
#   full     build the images and run every test (the default whenever in doubt)
#   digests  only digests.md changed, on a chore/digests-* branch: verify the digests on ghcr.io
#   docs     only documentation changed: nothing to build
#   draft    a draft PR: lint + gitleaks + render-only launcher tests; full build when marked ready
# Usage: ci-classify.sh <event> <base-rev> <head-rev> <branch> <draft:true|false>
# The changed files are `git diff base...head` (from the merge base, so a moving main is ignored).
# Pushes to main and workflow_dispatch stay full, EXCEPT the dispatch the publish workflow sends to
# its own digests PR (chore/digests-*, digests.md only): that is the digests path.
set -euo pipefail
event=${1:?event}; base=${2:?base rev}; head=${3:?head rev}; branch=${4:?branch}; draft=${5:-false}

mapfile -t files < <(git diff --name-only "$base...$head")
printf 'changed: %s\n' "${files[@]:-<none>}" >&2

digests_only=false
if [ "${#files[@]}" -eq 1 ] && [ "${files[0]}" = digests.md ] && [[ $branch == chore/digests-* ]]; then
  digests_only=true
fi

# Docs: any *.md or anything under docs/, but never digests.md (it pins the images) and never a file
# under images/ or tests/ (a Dockerfile could COPY it; a test could read it).
docs_only=true
[ "${#files[@]}" -gt 0 ] || docs_only=false     # an empty diff proves nothing: build
for f in "${files[@]}"; do
  case $f in
    digests.md|images/*|tests/*) docs_only=false ;;
    docs/*|*.md) ;;
    *) docs_only=false ;;
  esac
done

case $event in
  workflow_dispatch)
    if $digests_only; then echo digests; else echo full; fi ;;
  pull_request)
    if $digests_only; then echo digests
    elif $docs_only; then echo docs
    elif [ "$draft" = true ]; then echo draft
    else echo full; fi ;;
  *) echo full ;;
esac
