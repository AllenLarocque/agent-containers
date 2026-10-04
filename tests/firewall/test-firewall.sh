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
# project-file merge: CI mounts a 50-project.txt containing exactly "httpbin.org"
allowed https://httpbin.org/get
[ "$fail" -eq 0 ] && echo "FIREWALL: ALL PASSED" || { echo "FIREWALL: FAILURES"; exit 1; }
