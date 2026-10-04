#!/usr/bin/env bash
# Run INSIDE a started container AS ROOT, AFTER `sudo init-firewall.sh`. Needs NET_ADMIN/NET_RAW
# (root is required to read iptables/ip6tables state; reachability does not depend on the uid).
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
# www.mozilla.org: Fastly CNAME + multiple A records (not www.gnu.org: it black-holes SYNs per source IP, see flake-report)
allowed https://www.mozilla.org/

# --- IPv6 must be default-DENY (fail closed), not unfiltered ---
if [ -e /proc/net/if_inet6 ]; then
  if ip6tables -S OUTPUT 2>&1 | grep -qx -- '-P OUTPUT DROP'; then echo "OK:   ip6tables OUTPUT policy is DROP"
  else echo "FAIL: ip6tables OUTPUT policy is not DROP (IPv6 egress unfiltered)"; fail=1; fi
else
  echo "SKIP: no IPv6 in this container"
fi

# --- DNS over TCP: allowed ONLY to the upstream resolver, never to any destination ---
tcp53=$(iptables -S OUTPUT | grep -- '-p tcp' | grep -- '--dport 53' || true)
if [ -n "$tcp53" ] && ! echo "$tcp53" | grep -qv -- ' -d '; then echo "OK:   TCP 53 OUTPUT rule exists and is destination-restricted"
else echo "FAIL: TCP 53 OUTPUT rule missing or not restricted to a destination: '$tcp53'"; fail=1; fi
[ "$fail" -eq 0 ] && echo "FIREWALL: ALL PASSED" || { echo "FIREWALL: FAILURES"; exit 1; }
