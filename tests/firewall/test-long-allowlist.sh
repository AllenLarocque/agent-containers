#!/usr/bin/env bash
# Run INSIDE a container AS ROOT, AFTER init-firewall.sh, with a 200-domain allowlist mounted as
# 70-long.txt (CI generates it). One joined ipset= line would exceed dnsmasq's config line limit;
# the script must write one ipset= (and one server=) line per domain, and DNS must still work.
set -uo pipefail
fail=0
ok(){ echo "OK:   $*"; }; bad(){ echo "FAIL: $*"; fail=1; }
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
curl -q -sSf --connect-timeout 10 https://cloud.r-project.org/src/contrib/PACKAGES.gz >/dev/null 2>&1 && ok "CRAN reachable" || bad "CRAN unreachable"
[ "$fail" -eq 0 ] && echo "LONG-ALLOWLIST: ALL PASSED" || { echo "LONG-ALLOWLIST: FAILURES"; exit 1; }
