#!/usr/bin/env bash
# Run INSIDE a started container AFTER `sudo init-firewall.sh`. Needs NET_ADMIN/NET_RAW.
set -uo pipefail
fail=0
blocked(){ if curl --connect-timeout 5 -s "$1" >/dev/null 2>&1; then echo "FAIL: $1 reachable, should be BLOCKED"; fail=1; else echo "OK:   $1 blocked"; fi; }
# TEMP-DIAG
diag(){ h=${1#https://}; h=${h%%/*}; echo "::group::DIAG $h"; date -u +%T.%N
  echo "--- dig A"; dig "$h" A @127.0.0.1 +noall +answer +stats
  echo "--- dig AAAA"; dig "$h" AAAA @127.0.0.1 +noall +answer
  echo "--- getent ahosts"; getent ahosts "$h"
  echo "--- ipset"; sudo ipset list allowed-domains | grep -v '^[0-9a-f.:/]*$' ; sudo ipset list allowed-domains | grep -E '^209\.51\.|^[0-9.]+(/[0-9]+)?( |$)' | head -200
  echo "--- iptables"; sudo iptables -L OUTPUT -n -v
  echo "--- curl -v (retry now)"; curl -v --connect-timeout 10 -sS -o /dev/null "$1" 2>&1 | head -60; echo "curl rc=${PIPESTATUS[0]}"
  echo "::endgroup::"; }
allowed(){ out=$(curl -v --connect-timeout 10 -sSf -o /dev/null "$1" 2>&1); rc=$?; if [ $rc -eq 0 ]; then echo "OK:   $1 reachable"; else echo "FAIL: $1 blocked, should be ALLOWED (curl rc=$rc)"; echo "$out" | head -40; diag "$1"; fail=1; fi; }
blocked https://example.com
allowed https://api.github.com/zen
allowed https://cloud.r-project.org/src/contrib/PACKAGES.gz
allowed https://packagemanager.posit.co/cran/__linux__/noble/latest/src/contrib/PACKAGES.gz
allowed https://predictiveecology.r-universe.dev/src/contrib/PACKAGES.gz
allowed https://bioconductor.org/packages/release/bioc/src/contrib/PACKAGES.gz
# Subdomain of a base domain (dnsmasq semantics)
allowed https://www.bioconductor.org/
# Project-file parsing fixtures (mounted by CI). Hosts here are NOT in the base allowlist.
# 40-extra.txt : "www.python.org" with NO trailing newline (file-boundary glue test)
# 50-project.txt: CRLF line, inline comment, blank, comment-only, last line w/o newline
allowed https://www.python.org/
allowed https://www.r-project.org/
allowed https://cran.r-project.org/
allowed https://www.gnu.org/
[ "$fail" -eq 0 ] && echo "FIREWALL: ALL PASSED" || { echo "FIREWALL: FAILURES"; exit 1; }
