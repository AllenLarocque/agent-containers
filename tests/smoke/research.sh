#!/usr/bin/env bash
set -euo pipefail
fail=0
# On failure, print the command, its exit code and the last 40 lines of its output (stdout+stderr).
check(){
  local d="$1"; shift; local out rc=0
  out=$("$@" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then echo "OK:   $d"; else
    echo "FAIL: $d (exit $rc): $*"; printf '%s\n' "$out" | tail -n 40 | sed 's/^/    | /'; fail=1
  fi
}
check "inherits gis smoke"  bash /tests/smoke/gis.sh
check "paper-tools MANIFEST exists and is readable by agent" bash -c 'id -un | grep -qx agent && test -r /opt/paper-tools/MANIFEST'
echo "INFO: paper tools: $(grep -c . /opt/paper-tools/MANIFEST || true) installed"
[ "$fail" -eq 0 ] && echo "SMOKE research: ALL PASSED" || { echo "SMOKE research: FAILURES"; exit 1; }
