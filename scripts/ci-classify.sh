#!/usr/bin/env bash
# Decide how much of CI a run needs. Prints ONE word on stdout:
#   full     build the images and run every test (the default whenever in doubt)
#   docs     only documentation changed: nothing to build
#   draft    a draft PR: lint + gitleaks + render-only launcher tests; full build when marked ready
# Usage: ci-classify.sh <event> <base-rev> <head-rev> <branch> <draft:true|false>
# The changed files are `git diff base...head` (from the merge base, so a moving main is ignored).
# Pushes to main and workflow_dispatch are always full.
set -euo pipefail
event=${1:?event}; base=${2:?base rev}; head=${3:?head rev}; : "${4:?branch}"; draft=${5:-false}   # $4 (branch) is still passed by ci.yml; unused since the digests mode went

mapfile -t files < <(git diff --name-only "$base...$head")
printf 'changed: %s\n' "${files[@]:-<none>}" >&2

# Docs: any *.md or anything under docs/, but never a file under images/ or tests/ (a Dockerfile could COPY it; a test could read it).
docs_only=true
[ "${#files[@]}" -gt 0 ] || docs_only=false     # an empty diff proves nothing: build
for f in "${files[@]}"; do
  case $f in
    images/*|tests/*) docs_only=false ;;
    docs/*|*.md) ;;
    *) docs_only=false ;;
  esac
done

case $event in
  pull_request)
    if $docs_only; then echo docs
    elif [ "$draft" = true ]; then echo draft
    else echo full; fi ;;
  *) echo full ;;
esac
