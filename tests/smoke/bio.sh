#!/usr/bin/env bash
set -euo pipefail
fail=0
check(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "OK:   $d"; else echo "FAIL: $d"; fail=1; fi; }
check "inherits base smoke"   bash /tests/smoke/base.sh
check "mafft"                 bash -c 'mafft --version 2>&1 | grep -q v7'
check "cutadapt"              cutadapt --version
check "fasttree"              bash -c 'fasttree 2>&1 | grep -qi fasttree'
# libglpk-dev / libmagick++-dev come from BASE (not reinstalled in bio); this proves bio inherits them.
check "glpk + magick headers (from base)" bash -c 'dpkg -s libglpk-dev libmagick++-dev'
check "sklearn env 1.9.0"     bash -c '/opt/conda/envs/sklearn/bin/python -c "import sklearn; assert sklearn.__version__.startswith(\"1.9\")"'
check "picrust2 env"          bash -c 'test -x /opt/conda/envs/picrust2/bin/picrust2_pipeline.py'
[ "$fail" -eq 0 ] && echo "SMOKE bio: ALL PASSED" || { echo "SMOKE bio: FAILURES"; exit 1; }
