#!/usr/bin/env bash
# Run INSIDE a container AS ROOT whose resolver is DEAD (docker run --dns 192.0.2.1), BEFORE any
# firewall init. A setup step (the api.github.com/meta fetch needs DNS) must fail mid-way, and the
# container must then be CLOSED, not open: non-zero exit, -P OUTPUT/INPUT/FORWARD DROP (v4 and v6)
# and no egress, even to a literal IP (so a dead resolver cannot mask an open firewall).
set -uo pipefail
fail=0
ok(){ echo "OK:   $*"; }; bad(){ echo "FAIL: $*"; fail=1; }
out=$(timeout 300 /usr/local/bin/init-firewall.sh 2>&1); rc=$?
echo "$out" | tail -5
[ "$rc" -ne 0 ] && ok "init-firewall.sh exited non-zero ($rc) on a mid-setup failure" || bad "init-firewall.sh exited 0 despite a dead resolver"
for ch in INPUT FORWARD OUTPUT; do
  iptables -S "$ch" 2>&1 | grep -qx -- "-P $ch DROP" && ok "iptables policy $ch DROP after failure" || bad "iptables policy $ch NOT DROP after failure (fail-open window)"
done
if [ -e /proc/net/if_inet6 ]; then
  ip6tables -S OUTPUT 2>&1 | grep -qx -- '-P OUTPUT DROP' && ok "ip6tables policy OUTPUT DROP after failure" || bad "ip6tables OUTPUT NOT DROP after failure"
fi
if curl -s --connect-timeout 5 https://1.1.1.1/ >/dev/null 2>&1; then bad "reached https://1.1.1.1/ after a failed setup"; else ok "https://1.1.1.1/ blocked after failed setup"; fi
if curl -s --connect-timeout 5 https://example.com >/dev/null 2>&1; then bad "reached https://example.com after a failed setup"; else ok "https://example.com blocked after failed setup"; fi
[ "$fail" -eq 0 ] && echo "FAIL-CLOSED: ALL PASSED" || { echo "FAIL-CLOSED: FAILURES"; exit 1; }
