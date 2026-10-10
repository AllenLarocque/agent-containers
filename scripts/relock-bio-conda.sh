#!/usr/bin/env bash
# Regenerate images/bio/conda-locks/<env>.txt (explicit conda locks, linux-64 ONLY). Needs docker.
#
#   scripts/relock-bio-conda.sh from-image <image-ref>   # copy the envs of an image that PASSED the bio smoke
#   scripts/relock-bio-conda.sh solve [<image-ref>]      # fresh solve of SPECS below with that image's conda
#                                                        #   (default ghcr.io/allenlarocque/spades-bio:latest)
#
# from-image is the safe path (the lock is exactly what was smoke-tested). A fresh `solve` is how versions
# move: it is UNTESTED until the PR's full CI build-test runs the bio smoke on an image built from it.
# Either way: review `git diff images/bio/conda-locks`, commit, open a PR, and let CI build + smoke it.
# The Dockerfile installs each lock with `conda create --file` (no solver) and fails on any drift.
set -euo pipefail

# Top-level specs, used only by `solve`. Changing a version here = re-solve + review the lock diff.
declare -A SPECS=(
  [picrust2]="-c conda-forge -c bioconda picrust2=2.5.2"
  [sklearn]="-c conda-forge python=3.12 scikit-learn=1.9.0 joblib numpy scipy biopython"
)
ENVS=(picrust2 sklearn)

here=$(cd "$(dirname "$0")/.." && pwd)
out_dir="$here/images/bio/conda-locks"
mode=${1:-}; image=${2:-}
case $mode in
  from-image) [ -n "$image" ] || { echo "usage: $0 from-image <image-ref>" >&2; exit 2; } ;;
  solve) image=${image:-ghcr.io/allenlarocque/spades-bio:latest} ;;
  *) sed -n '2,11p' "$0" >&2; exit 2 ;;
esac

docker pull --platform linux/amd64 -q "$image" >/dev/null
ref=$(docker image inspect --format '{{index .RepoDigests 0}}' "$image" 2>/dev/null || echo "$image")

for e in "${ENVS[@]}"; do
  if [ "$mode" = from-image ]; then
    source_line="# Source: $ref (linux/amd64), env /opt/conda/envs/$e: copied from an image that passed the bio smoke."
    body=$(docker run --rm --platform linux/amd64 -u root --entrypoint /opt/conda/bin/conda "$image" \
             list -n "$e" --explicit --md5)
  else
    source_line="# Source: fresh solve of \`${SPECS[$e]}\` with the conda in $ref (linux/amd64), $(date -u +%Y-%m-%d)."
    # shellcheck disable=SC2086  # SPECS values are word lists on purpose
    body=$(docker run --rm --platform linux/amd64 -u root --entrypoint /bin/bash "$image" -c \
             "set -e; /opt/conda/bin/conda create -q -y -p /tmp/relock --override-channels ${SPECS[$e]} >&2
              /opt/conda/bin/conda list -p /tmp/relock --explicit --md5")
  fi
  pkgs=$(grep -E '^https://' <<<"$body" || true)
  n=$(grep -c . <<<"$pkgs" || true)
  [ "$n" -gt 0 ] || { echo "no packages for env $e" >&2; exit 1; }
  # Every package line must carry an md5 (conda verifies it at install time).
  if grep -vqE '#[0-9a-f]{32}$' <<<"$pkgs"; then echo "env $e: a package line has no #md5" >&2; exit 1; fi
  {
    cat <<EOF
# Explicit conda lock for the spades-bio \`$e\` env. linux-64 ONLY. Do not hand-edit.
# Installed by images/bio/Dockerfile with \`conda create -n $e --file <this file>\`: no solver runs, and
# conda verifies every package against the #md5 on its URL. The build fails if the installed env's
# \`conda list --explicit --md5\` differs from the package lines below.
$source_line
# Regenerate: scripts/relock-bio-conda.sh (see images/bio/README.md).
# platform: linux-64
@EXPLICIT
EOF
    printf '%s\n' "$pkgs"
  } > "$out_dir/$e.txt"
  echo "wrote $out_dir/$e.txt ($n packages)"
done
echo "Hosts in the locks (must be reachable at BUILD time; add to a project allowlist only for runtime conda use):"
grep -hoE '^https://[^/]+' "$out_dir"/*.txt | sort | uniq -c
