#!/usr/bin/env bash
# Run INSIDE a container AS ROOT, AFTER init-firewall.sh, with a 200-domain allowlist mounted as
# 70-long.txt (CI generates it). One joined ipset= line would exceed dnsmasq's config line limit;
# the script must write one ipset= (and one server=) line per domain, and DNS must still work.
set -uo pipefail
fail=0
ok(){ echo "OK:   $*"; }; bad(){ echo "FAIL: $*"; fail=1; }
# Reachable = any HTTP answer (code != 000): the firewall let DNS+TCP+TLS through. An HTTP error (rate limit,
# a 5xx) is the site's answer, not a block; `curl -f` counted it as blocked and CI failed at random. One retry.
# On failure REACH_CODE = "<http code> <ip tried> exit <curl exit>" (6 DNS, 7 refused, 28 timeout, 35/60 TLS).
reach(){ local c rc i; for i in 1 2; do c=$(curl -q -s -o /dev/null -w '%{http_code} %{remote_ip}' --connect-timeout 10 --max-time 30 "$1" 2>/dev/null); rc=$?; [ -n "$c" ] && [ "${c%% *}" != 000 ] && return 0; [ "$i" = 1 ] && sleep 3; done; REACH_CODE="${c:-000} exit $rc"; return 1; }
conf=/etc/dnsmasq.d/allowlist.conf
n=$(grep -cv '^[[:space:]]*\(#\|$\)' /etc/firewall/allowlist.d/70-long.txt)
[ "$n" -ge 200 ] && ok "long allowlist has $n domains" || bad "long allowlist has only $n domains"
grep -q '^ipset=/host199\.' "$conf" && ok "last synthetic domain present in dnsmasq config" || bad "synthetic domains missing from dnsmasq config"
multi=$(grep '^ipset=' "$conf" | grep -c '^ipset=/[^/]*/[^/]*/' || true)
[ "$multi" -eq 0 ] && ok "every ipset= line names exactly one domain" || bad "$multi ipset= line(s) join several domains"
[ "$(grep -c '^ipset=' "$conf")" -eq "$(grep -c '^server=/' "$conf")" ] && ok "one ipset= line per server= line" || bad "ipset=/server= line counts differ"
longest=$(awk '{ if (length($0) > m) m = length($0) } END { print m }' "$conf")
[ "$longest" -lt 1000 ] && ok "longest dnsmasq config line is $longest chars" || bad "a dnsmasq config line is $longest chars"
pgrep -x dnsmasq >/dev/null && ok "dnsmasq running" || bad "dnsmasq not running"
[ -n "$(dig -r +short +time=3 +tries=2 @127.0.0.1 api.github.com A | grep -E '^[0-9.]+$')" ] && ok "api.github.com resolves" || bad "api.github.com does not resolve"
reach https://cloud.r-project.org/src/contrib/PACKAGES.gz && ok "CRAN reachable" || bad "CRAN unreachable (curl: $REACH_CODE)"
[ "$fail" -eq 0 ] && echo "LONG-ALLOWLIST: ALL PASSED" || { echo "LONG-ALLOWLIST: FAILURES"; exit 1; }
