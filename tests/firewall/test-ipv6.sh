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
# EXACT ruleset: no IPv6 allowlist, so ANY rule beyond these (or a broadened one) is a failure.
expect=$(cat <<'EOF2'
-P INPUT DROP
-P FORWARD DROP
-P OUTPUT DROP
-A INPUT -i lo -j ACCEPT
-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
EOF2
)
rules=$(ip6tables -S 2>&1)
if [ "$rules" = "$expect" ]; then ok "ip6tables -S equals the expected snapshot"
else bad "ip6tables -S differs from the expected snapshot (- expected, + actual):"; diff <(echo "$expect") <(echo "$rules") | sed 's/^/        /'; fi
if curl -6 --connect-timeout 5 -s https://www.google.com >/dev/null 2>&1; then bad "curl -6 reached https://www.google.com"; else ok "curl -6 blocked"; fi
if curl -6 --connect-timeout 5 -s 'https://[2606:4700:4700::1111]/' >/dev/null 2>&1; then bad "curl -6 reached a literal IPv6 address"; else ok "curl -6 literal address blocked"; fi
[ "$fail" -eq 0 ] && echo "IPV6: ALL PASSED" || { echo "IPV6: FAILURES"; exit 1; }
