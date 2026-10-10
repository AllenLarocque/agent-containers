#!/usr/bin/env bash
set -euo pipefail
fail=0
# On failure, print the command, its exit code and the last 40 lines of its output (stdout+stderr):
# a failing check must be diagnosable from the smoke log alone.
check(){
  local d="$1"; shift; local out rc=0
  out=$("$@" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then echo "OK:   $d"; else
    echo "FAIL: $d (exit $rc): $*"; printf '%s\n' "$out" | tail -n 40 | sed 's/^/    | /'; fail=1
  fi
}
check "inherits base smoke"   bash /tests/smoke/base.sh
check "mafft"                 bash -c 'mafft --version 2>&1 | grep -q v7'
check "cutadapt"              cutadapt --version
check "fasttree"              bash -c 'fasttree 2>&1 | grep -qi fasttree'
# libglpk-dev / libmagick++-dev come from BASE (not reinstalled in bio); this proves bio inherits them.
check "glpk + magick headers (from base)" bash -c 'dpkg -s libglpk-dev libmagick++-dev'
check "sklearn env 1.9.0"     bash -c '/opt/conda/envs/sklearn/bin/python -c "import sklearn; assert sklearn.__version__.startswith(\"1.9\")"'
check "picrust2 runs (-h)"     /opt/conda/envs/picrust2/bin/picrust2_pipeline.py -h
check "sklearn env imports numpy/scipy/joblib/Bio" /opt/conda/envs/sklearn/bin/python -c "import numpy, scipy, joblib, Bio"
check "picrust2 spec.txt is an explicit spec" bash -c 'grep -q "^@EXPLICIT" /opt/conda/envs/picrust2/spec.txt'
check "sklearn spec.txt is an explicit spec"  bash -c 'grep -q "^@EXPLICIT" /opt/conda/envs/sklearn/spec.txt'
# The build already fails on drift from images/bio/conda-locks/*.txt; this proves md5s were recorded.
check "spec.txt pins md5 for every package" bash -c 'for e in picrust2 sklearn; do f=/opt/conda/envs/$e/spec.txt; n=$(grep -c "^https://" $f); m=$(grep -cE "^https://.*#[0-9a-f]{32}$" $f); echo "$e: $m/$n md5-pinned"; [ "$n" -gt 0 ] && [ "$n" = "$m" ] || exit 1; done'
echo "INFO: $(du -sh /opt/conda | cut -f1) /opt/conda"
[ "$fail" -eq 0 ] && echo "SMOKE bio: ALL PASSED" || { echo "SMOKE bio: FAILURES"; exit 1; }
