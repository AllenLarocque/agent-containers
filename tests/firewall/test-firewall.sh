#!/usr/bin/env bash
# Run INSIDE a started container AFTER `sudo init-firewall.sh`. Needs NET_ADMIN/NET_RAW.
set -uo pipefail
fail=0
blocked(){ if curl --connect-timeout 5 -s "$1" >/dev/null 2>&1; then echo "FAIL: $1 reachable, should be BLOCKED"; fail=1; else echo "OK:   $1 blocked"; fi; }
allowed(){ if curl --connect-timeout 10 -sSf "$1" >/dev/null 2>&1; then echo "OK:   $1 reachable"; else echo "FAIL: $1 blocked, should be ALLOWED"; fail=1; fi; }
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
