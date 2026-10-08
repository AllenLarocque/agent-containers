#!/usr/bin/env bash
# Run INSIDE a started container AS ROOT, AFTER `sudo init-firewall.sh`. Needs NET_ADMIN/NET_RAW
# (root is required to read iptables/ip6tables state). Agent-side egress checks (owner-scoped DNS,
# port 22, Docker's resolver) live in test-agent-egress.sh and run as the agent user.
# Env: EXPECT_UPSTREAM = the container's ORIGINAL resolver (captured from /etc/resolv.conf by the CI
#      step BEFORE the firewall ran; never read back from the firewall's own state).
set -uo pipefail
fail=0
ok(){ echo "OK:   $*"; }; bad(){ echo "FAIL: $*"; fail=1; }
: "${EXPECT_UPSTREAM:?EXPECT_UPSTREAM must be set to the pre-firewall resolver}"
blocked(){ if curl --connect-timeout 5 -s "$1" >/dev/null 2>&1; then bad "$1 reachable, should be BLOCKED"; else ok "$1 blocked"; fi; }
allowed(){ if curl --connect-timeout 10 -sSf "$1" >/dev/null 2>&1; then ok "$1 reachable"; else bad "$1 blocked, should be ALLOWED"; fi; }
blocked https://example.com
blocked https://1.1.1.1/
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

# --- EXACT rule snapshots: ANY new or broadened rule turns this red. ---
DUID=$(id -u dnsmasq 2>/dev/null) || { bad "no dnsmasq user in the image"; DUID=MISSING; }
GW=$(ip -4 route show default | awk '{print $3; exit}')
expect_v4=$(sed -e "s|@UP@|$EXPECT_UPSTREAM|g" -e "s|@DUID@|$DUID|g" -e "s|@GW@|$GW|g" <<'EOF'
-P INPUT DROP
-P FORWARD DROP
-P OUTPUT DROP
-A INPUT -i lo -j ACCEPT
-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A INPUT -s @GW@/32 -p tcp -m tcp --dport 3773 -j ACCEPT
-A OUTPUT -d 127.0.0.11/32 -m owner ! --uid-owner @DUID@ -j REJECT --reject-with icmp-port-unreachable
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A OUTPUT -d @UP@/32 -p udp -m udp --dport 53 -m owner --uid-owner @DUID@ -j ACCEPT
-A OUTPUT -d @UP@/32 -p tcp -m tcp --dport 53 -m owner --uid-owner @DUID@ -j ACCEPT
-A OUTPUT -p tcp -m set --match-set allowed-domains dst -m multiport --dports 22,80,443 -j ACCEPT
-A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
EOF
)
expect_v6=$(cat <<'EOF'
-P INPUT DROP
-P FORWARD DROP
-P OUTPUT DROP
-A INPUT -i lo -j ACCEPT
-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
EOF
)
got_v4=$(iptables -S 2>&1)
if [ "$got_v4" = "$expect_v4" ]; then ok "iptables -S equals the expected snapshot"
else bad "iptables -S differs from the expected snapshot (- expected, + actual):"; diff <(echo "$expect_v4") <(echo "$got_v4") | sed 's/^/        /'; fi
echo "---- iptables -S (actual)"; echo "$got_v4" | sed 's/^/        /'
if got_v6=$(ip6tables -S 2>&1); then
  if [ "$got_v6" = "$expect_v6" ]; then ok "ip6tables -S equals the expected snapshot"
  else bad "ip6tables -S differs from the expected snapshot (- expected, + actual):"; diff <(echo "$expect_v6") <(echo "$got_v6") | sed 's/^/        /'; fi
  echo "---- ip6tables -S (actual)"; echo "$got_v6" | sed 's/^/        /'
elif [ -e /proc/net/if_inet6 ]; then
  bad "ip6tables -S failed although the kernel has IPv6: $got_v6"
else
  echo "SKIP: no IPv6 in this container"
fi
# nat: only Docker's embedded-DNS plumbing may survive the flush.
extra_nat=$(iptables -t nat -S | grep -v -- '^-P ' | grep -v -- '^-N DOCKER_OUTPUT$' | grep -v -- '^-N DOCKER_POSTROUTING$' | grep -v '127\.0\.0\.11' || true)
[ -z "$extra_nat" ] && ok "nat table holds only Docker DNS rules" || bad "unexpected nat rules: $extra_nat"

# --- the persisted ORIGINAL resolver (rerun idempotency) ---
[ "$(cat /run/firewall-upstream 2>/dev/null)" = "$EXPECT_UPSTREAM" ] && ok "/run/firewall-upstream holds the original resolver" \
  || bad "/run/firewall-upstream is '$(cat /run/firewall-upstream 2>/dev/null)', want '$EXPECT_UPSTREAM'"
grep -qx 'nameserver 127.0.0.1' /etc/resolv.conf && ok "resolv.conf points at dnsmasq" || bad "resolv.conf does not point at 127.0.0.1"

# --- dnsmasq: dedicated user, allowlist-only forwarding (no default server) ---
# Every LIVE dnsmasq process: real, effective, saved and fs uid must all be the dnsmasq uid.
# (Zombies are skipped: dnsmasq's daemonising fork leaves one when PID 1 does not reap, e.g.
# `sleep infinity` without --init. A zombie holds no sockets and runs no code.)
live=0
for p in $(pgrep -x dnsmasq || true); do
  st=$(awk '/^State:/{print $2}' "/proc/$p/status" 2>/dev/null)
  uids=$(awk '/^Uid:/{print $2,$3,$4,$5}' "/proc/$p/status" 2>/dev/null)
  echo "        dnsmasq pid $p: State $st Uid $uids | $(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)"
  [ "$st" = Z ] && continue
  live=$((live+1))
  [ "$uids" = "$DUID $DUID $DUID $DUID" ] && ok "dnsmasq pid $p runs as uid $DUID (dnsmasq)" || bad "dnsmasq pid $p has Uid '$uids', want all $DUID"
done
[ "$live" -ge 1 ] && ok "$live live dnsmasq process(es)" || bad "no live dnsmasq process"
conf=/etc/dnsmasq.d/allowlist.conf
grep -Eq '^server=[^/]' "$conf" && bad "dnsmasq has a default server= line (forwards every name)" || ok "dnsmasq has no default server= line"
grep -qx "server=/github.com/$EXPECT_UPSTREAM" "$conf" && ok "dnsmasq forwards github.com" || bad "no server=/github.com/ line"
# Non-vacuity for the owner match: the dnsmasq uid CAN reach the upstream (so a blocked agent query
# below is the owner rule, not a dead resolver).
if setpriv --reuid="$DUID" --regid="$(id -g dnsmasq 2>/dev/null)" --clear-groups dig +short +time=3 +tries=2 @"$EXPECT_UPSTREAM" api.github.com A 2>/dev/null | grep -Eq '^[0-9]+(\.[0-9]+){3}$'; then
  ok "upstream $EXPECT_UPSTREAM answers the dnsmasq uid"
else bad "upstream $EXPECT_UPSTREAM does not answer the dnsmasq uid"; fi
[ "$fail" -eq 0 ] && echo "FIREWALL: ALL PASSED" || { echo "FIREWALL: FAILURES"; exit 1; }
