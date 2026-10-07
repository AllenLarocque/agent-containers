#!/usr/bin/env bash
# Run INSIDE a container AS ROOT, BEFORE any firewall init, with a WORKING resolver. 127.0.0.1:53 is
# occupied first, so init-firewall.sh gets through the temporary rules, the ipset and the GitHub meta
# fetch and only then fails (dnsmasq cannot bind). The container must be left CLOSED: non-zero exit,
# every policy DROP, no egress to a literal IP, and none of the setup-only rules left behind.
set -uo pipefail
fail=0
ok(){ echo "OK:   $*"; }; bad(){ echo "FAIL: $*"; fail=1; }
# A renamed dnsmasq holds 127.0.0.1:53 (UDP+TCP); the firewall only ever stops processes named dnsmasq.
cp /usr/sbin/dnsmasq /tmp/dns-blocker
/tmp/dns-blocker -C /dev/null --listen-address=127.0.0.1 --bind-interfaces --port=53 --no-resolv --pid-file=/tmp/dns-blocker.pid
ss -lnu | grep -q '127.0.0.1:53 ' && ok "127.0.0.1:53 occupied by the blocker" || bad "blocker did not bind 127.0.0.1:53 (test not exercising a late failure)"
out=$(timeout 300 /usr/local/bin/init-firewall.sh 2>&1); rc=$?
echo "$out" | tail -8 | sed 's/^/        /'
[ "$rc" -ne 0 ] && ok "init-firewall.sh exited non-zero ($rc)" || bad "init-firewall.sh exited 0 although dnsmasq could not start"
# Non-vacuity: the failure really happened AFTER the meta fetch populated the ipset.
echo "$out" | grep -q 'Adding GitHub range' && ok "failure happened after the GitHub meta fetch" || bad "failure happened before the meta fetch (not a late failure)"
for ch in INPUT FORWARD OUTPUT; do
  iptables -S "$ch" 2>&1 | grep -qx -- "-P $ch DROP" && ok "iptables policy $ch DROP after failure" || bad "iptables policy $ch NOT DROP after failure"
done
if ip6tables -S >/dev/null 2>&1; then
  for ch in INPUT FORWARD OUTPUT; do
    ip6tables -S "$ch" 2>&1 | grep -qx -- "-P $ch DROP" && ok "ip6tables policy $ch DROP after failure" || bad "ip6tables policy $ch NOT DROP after failure"
  done
fi
if curl -s --connect-timeout 5 https://1.1.1.1/ >/dev/null 2>&1; then bad "reached https://1.1.1.1/ after a failed setup"; else ok "https://1.1.1.1/ blocked after failed setup"; fi
left=$(iptables -S OUTPUT | grep -- '--dport 443 -j ACCEPT' || true)
[ -z "$left" ] && ok "no leftover temporary 443 ACCEPT rule" || bad "leftover temporary rule(s): $left"
# Only the setup baseline may remain: loopback, established, and the dnsmasq-uid upstream DNS.
DUID=$(id -u dnsmasq 2>/dev/null || echo MISSING)
extra=$(iptables -S | grep -- '-j ACCEPT' | grep -v -- '-[io] lo -j ACCEPT$' | grep -v -- '--state RELATED,ESTABLISHED -j ACCEPT$' \
        | grep -v -- "--dport 53 -m owner --uid-owner $DUID -j ACCEPT\$" || true)
[ -z "$extra" ] && ok "no ACCEPT rule beyond the setup baseline" || bad "unexpected ACCEPT rules after failure: $extra"
kill "$(cat /tmp/dns-blocker.pid)" 2>/dev/null || true
[ "$fail" -eq 0 ] && echo "LATE-FAILURE: ALL PASSED" || { echo "LATE-FAILURE: FAILURES"; exit 1; }
