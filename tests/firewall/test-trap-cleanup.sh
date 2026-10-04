#!/usr/bin/env bash
# Run INSIDE a container AS ROOT, BEFORE any firewall init. The GitHub meta fetch is made to fail
# WHILE the temporary HTTPS rules exist, with no test-only code in the script: a fake resolver on
# 127.0.0.53 (the container's "original" resolver for this test) answers api.github.com with
# 127.0.0.54, where nothing listens on 443. The EXIT trap must remove the temporary rules.
set -uo pipefail
fail=0
ok(){ echo "OK:   $*"; }; bad(){ echo "FAIL: $*"; fail=1; }
cp /usr/sbin/dnsmasq /tmp/dns-fake      # renamed: the firewall only stops processes named dnsmasq
/tmp/dns-fake -C /dev/null --listen-address=127.0.0.53 --bind-interfaces --port=53 --no-resolv \
  --address=/api.github.com/127.0.0.54 --pid-file=/tmp/dns-fake.pid
echo 'nameserver 127.0.0.53' > /etc/resolv.conf
[ "$(dig -r +short +time=2 +tries=1 @127.0.0.53 api.github.com A)" = 127.0.0.54 ] && ok "fake resolver maps api.github.com -> 127.0.0.54" \
  || bad "fake resolver not answering (test not exercising the meta-fetch failure)"
out=$(timeout 300 /usr/local/bin/init-firewall.sh 2>&1); rc=$?
echo "$out" | tail -6 | sed 's/^/        /'
[ "$rc" -ne 0 ] && ok "init-firewall.sh exited non-zero ($rc)" || bad "init-firewall.sh exited 0 although the meta fetch cannot succeed"
# Non-vacuity: the temporary rule really was installed, and the failure was the meta fetch.
echo "$out" | grep -q 'Temporary setup rules: HTTPS to api.github.com at 127.0.0.54' && ok "temporary 443 rule to 127.0.0.54 was installed" \
  || bad "no evidence the temporary rule was installed"
echo "$out" | grep -q 'Adding GitHub range' && bad "meta fetch succeeded (wrong failure point)" || ok "failure was at the meta fetch"
left=$(iptables -S OUTPUT | grep -- '--dport 443 -j ACCEPT' || true)
[ -z "$left" ] && ok "EXIT trap removed the temporary 443 ACCEPT rule" || bad "temporary rule left behind: $left"
for ch in INPUT FORWARD OUTPUT; do
  iptables -S "$ch" | grep -qx -- "-P $ch DROP" && ok "iptables policy $ch DROP" || bad "iptables policy $ch NOT DROP"
done
DUID=$(id -u dnsmasq)
extra=$(iptables -S | grep -- '-j ACCEPT' | grep -v -- '-[io] lo -j ACCEPT$' | grep -v -- '--state RELATED,ESTABLISHED -j ACCEPT$' \
        | grep -v -- "--dport 53 -m owner --uid-owner $DUID -j ACCEPT\$" || true)
[ -z "$extra" ] && ok "no ACCEPT rule beyond the setup baseline" || bad "unexpected ACCEPT rules: $extra"
kill "$(cat /tmp/dns-fake.pid)" 2>/dev/null || true
[ "$fail" -eq 0 ] && echo "TRAP-CLEANUP: ALL PASSED" || { echo "TRAP-CLEANUP: FAILURES"; exit 1; }
