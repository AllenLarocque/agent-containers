#!/usr/bin/env bash
# Run INSIDE a container on an IPv6-ENABLED Docker network, AS ROOT, AFTER init-firewall.sh.
# Asserts ip6tables POLICY STATE (not reachability: a runner may have no external IPv6 route,
# so a curl failure alone cannot tell fixed from unfixed).
set -uo pipefail
fail=0
ok(){ echo "OK:   $*"; }; bad(){ echo "FAIL: $*"; fail=1; }
# Guard against a vacuous pass: this job is only meaningful if the container really has IPv6.
if awk '$6!="lo"{f=1} END{exit !f}' /proc/net/if_inet6 2>/dev/null; then ok "container has a non-loopback IPv6 address"
else bad "no IPv6 address on this network - the IPv6 path is NOT being exercised"; fi
for ch in INPUT FORWARD OUTPUT; do
  ip6tables -S "$ch" 2>&1 | grep -qx -- "-P $ch DROP" && ok "ip6tables policy $ch DROP" || bad "ip6tables policy $ch is not DROP"
done
rules=$(ip6tables -S 2>&1)
echo "$rules" | grep -q -- '-A INPUT -i lo -j ACCEPT'  && ok "ip6 INPUT allows lo"  || bad "ip6 INPUT lo accept missing"
echo "$rules" | grep -q -- '-A OUTPUT -o lo -j ACCEPT' && ok "ip6 OUTPUT allows lo" || bad "ip6 OUTPUT lo accept missing"
echo "$rules" | grep -Eq -- '-A OUTPUT .*ESTABLISHED,RELATED.*-j ACCEPT|-A OUTPUT .*RELATED,ESTABLISHED.*-j ACCEPT' && ok "ip6 OUTPUT allows ESTABLISHED,RELATED" || bad "ip6 OUTPUT established accept missing"
# No IPv6 allowlist: the only ACCEPTs may be lo and established/related.
extra=$(echo "$rules" | grep -- '-j ACCEPT' | grep -v -- '-[io] lo ' | grep -v -- 'ESTABLISHED' | grep -v -- 'RELATED' || true)
[ -z "$extra" ] && ok "no other ip6 ACCEPT rules" || { bad "unexpected ip6 ACCEPT rules: $extra"; }
if curl -6 --connect-timeout 5 -s https://www.google.com >/dev/null 2>&1; then bad "curl -6 reached https://www.google.com"; else ok "curl -6 blocked"; fi
if curl -6 --connect-timeout 5 -s 'https://[2606:4700:4700::1111]/' >/dev/null 2>&1; then bad "curl -6 reached a literal IPv6 address"; else ok "curl -6 literal address blocked"; fi
[ "$fail" -eq 0 ] && echo "IPV6: ALL PASSED" || { echo "IPV6: FAILURES"; exit 1; }
