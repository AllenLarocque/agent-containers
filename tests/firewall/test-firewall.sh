#!/usr/bin/env bash
# Run INSIDE a started container AS ROOT, AFTER `sudo init-firewall.sh`. Needs NET_ADMIN/NET_RAW
# (root is required to read iptables/ip6tables state). Agent-side egress checks (owner-scoped DNS,
# port 22, Docker's resolver) live in test-agent-egress.sh and run as the agent user.
# Env: EXPECT_UPSTREAM = the container's ORIGINAL resolver (captured from /etc/resolv.conf by the CI
#      step BEFORE the firewall ran; never read back from the firewall's own state).
#      EXPECT_T3_CONNECT = 1 when the CI step mounted /etc/firewall/t3-connect with T3_CONNECT=1,
#      publish when it held T3_CONNECT=publish (t3.codes only, no tunnel edge)
#      (default 0: the rules must be exactly the ones without the feature).
#      EXPECT_RSTUDIO = 1 when the CI step mounted /etc/firewall/rstudio with RSTUDIO=1 (default 0:
#      exactly the rules without RStudio Server).
#      EXPECT_FTP = 1 when the CI step mounted /etc/firewall/ftp-hosts (default 0: exactly the rules
#      without FTP, and nothing of ours in the raw table).
set -uo pipefail
fail=0
ok(){ echo "OK:   $*"; }; bad(){ echo "FAIL: $*"; fail=1; }
: "${EXPECT_UPSTREAM:?EXPECT_UPSTREAM must be set to the pre-firewall resolver}"
EXPECT_T3_CONNECT=${EXPECT_T3_CONNECT:-0}
EXPECT_RSTUDIO=${EXPECT_RSTUDIO:-0}
EXPECT_FTP=${EXPECT_FTP:-0}
# Reachable = any HTTP answer (code != 000): the firewall let DNS+TCP+TLS through. An HTTP error (rate limit,
# a 5xx) is the site's answer, not a block; `curl -f` counted it as blocked and CI failed at random. One retry.
reach(){ local c i; for i in 1 2; do c=$(curl -q -s -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 30 "$1" 2>/dev/null); [ "${c:-000}" != 000 ] && return 0; [ "$i" = 1 ] && sleep 3; done; REACH_CODE=${c:-000}; return 1; }
blocked(){ if curl --connect-timeout 5 -s "$1" >/dev/null 2>&1; then bad "$1 reachable, should be BLOCKED"; else ok "$1 blocked"; fi; }
allowed(){ if reach "$1"; then ok "$1 reachable"; else bad "$1 blocked, should be ALLOWED (curl: $REACH_CODE)"; fi; }
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
@RS@-A OUTPUT -d 127.0.0.11/32 -m owner ! --uid-owner @DUID@ -j REJECT --reject-with icmp-port-unreachable
-A OUTPUT -o lo -j ACCEPT
-A OUTPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A OUTPUT -d @UP@/32 -p udp -m udp --dport 53 -m owner --uid-owner @DUID@ -j ACCEPT
-A OUTPUT -d @UP@/32 -p tcp -m tcp --dport 53 -m owner --uid-owner @DUID@ -j ACCEPT
-A OUTPUT -p tcp -m set --match-set allowed-domains dst -m multiport --dports 22,80,443 -j ACCEPT
@T3@@FTP@-A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
EOF
)
# T3 Connect ON adds exactly these two rules (7844, the t3-tunnel set only); OFF and publish add nothing.
if [ "$EXPECT_T3_CONNECT" = 1 ]; then
  t3_rules='-A OUTPUT -p udp -m udp --dport 7844 -m set --match-set t3-tunnel dst -j ACCEPT
-A OUTPUT -p tcp -m tcp --dport 7844 -m set --match-set t3-tunnel dst -j ACCEPT
'
  expect_v4=${expect_v4/@T3@/$t3_rules}
else
  expect_v4=${expect_v4/@T3@/}
fi
# FTP ON adds exactly this filter rule (tcp 21, the ftp-hosts set only); OFF adds nothing.
if [ "$EXPECT_FTP" = 1 ]; then
  ftp_rule='-A OUTPUT -p tcp -m tcp --dport 21 -m set --match-set ftp-hosts dst -j ACCEPT
'
  expect_v4=${expect_v4/@FTP@/$ftp_rule}
else
  expect_v4=${expect_v4/@FTP@/}
fi
# RStudio Server ON adds exactly this INPUT rule (gateway only, like T3's); OFF adds nothing.
if [ "$EXPECT_RSTUDIO" = 1 ]; then
  rs_rule="-A INPUT -s $GW/32 -p tcp -m tcp --dport 8787 -j ACCEPT
"
  expect_v4=${expect_v4/@RS@/$rs_rule}
else
  expect_v4=${expect_v4/@RS@/}
fi
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

# --- T3 Connect: a separate ipset, filled only from argotunnel.com lookups (the SRV targets) ---
conf_has(){ grep -qx -- "$1" "$conf"; }
if [ "$EXPECT_T3_CONNECT" = 1 ]; then
  conf_has "server=/argotunnel.com/$EXPECT_UPSTREAM" && ok "dnsmasq forwards argotunnel.com" || bad "no server=/argotunnel.com/ line"
  conf_has "ipset=/argotunnel.com/t3-tunnel" && ok "argotunnel.com addresses go to t3-tunnel ONLY" || bad "no ipset=/argotunnel.com/t3-tunnel line"
  conf_has "ipset=/t3.codes/allowed-domains" && ok "t3.codes is allowlisted (22/80/443)" || bad "t3.codes not allowlisted"
  ipset list -n | grep -qx t3-tunnel && ok "ipset t3-tunnel exists" || bad "no ipset t3-tunnel"
  tips=()
  for t in $(dig -r +short +time=3 +tries=2 SRV _v2-origintunneld._tcp.argotunnel.com @127.0.0.1 | awk '{print $4}'); do
    mapfile -t -O "${#tips[@]}" tips < <(dig -r +short +time=3 +tries=2 "$t" A @127.0.0.1 | grep -E '^[0-9]+(\.[0-9]+){3}$')
  done
  [ "${#tips[@]}" -gt 0 ] && ok "SRV targets resolve via dnsmasq: ${tips[*]}" || bad "SRV targets of _v2-origintunneld._tcp.argotunnel.com do not resolve"
  for ip in "${tips[@]}"; do
    ipset test t3-tunnel "$ip" 2>/dev/null && ok "$ip is in t3-tunnel" || bad "$ip (SRV target) is NOT in t3-tunnel"
    ipset test allowed-domains "$ip" 2>/dev/null && bad "$ip (tunnel edge) is in allowed-domains (22/80/443)" || ok "$ip is not in allowed-domains"
  done
  # Every member of t3-tunnel must come from an argotunnel.com lookup: nothing else is ever added.
  others=$(ipset list t3-tunnel | sed -n '/^Members:/,$p' | tail -n +2 | grep -v '^$' | while read -r m; do
    printf '%s\n' "${tips[@]}" | grep -qx "${m%/32}" || echo "$m"; done)
  [ -z "$others" ] && ok "t3-tunnel holds only the SRV targets' addresses" || echo "NOTE: t3-tunnel also holds $others (other argotunnel.com lookups, e.g. by the firewall's priming)"
  # UDP (QUIC) really matches the udp rule: its packet counter moves for one datagram to an edge IP.
  if [ "${#tips[@]}" -gt 0 ]; then
    cnt(){ iptables -L OUTPUT -n -v -x | awk '/t3-tunnel/ && /dpt:7844/ && ($4=="udp" || $4=="17") {print $1}'; }
    before=$(cnt); echo probe > "/dev/udp/${tips[0]}/7844" 2>/dev/null; after=$(cnt)
    [ -n "$before" ] && [ "${after:-0}" -gt "$before" ] && ok "UDP to ${tips[0]}:7844 is ACCEPTed by the t3-tunnel udp rule ($before -> $after)" \
      || bad "UDP to ${tips[0]}:7844 did not match the t3-tunnel udp rule ($before -> $after)"
  fi
elif [ "$EXPECT_T3_CONNECT" = publish ]; then
  # Notifications only: t3.codes is allowlisted, but nothing tunnel-related exists.
  grep -q '^server=/t3\.codes/' "$conf" && ok "dnsmasq forwards t3.codes (publish)" || bad "no server=/t3.codes/ line (publish)"
  conf_has "ipset=/t3.codes/allowed-domains" && ok "t3.codes is allowlisted (22/80/443)" || bad "t3.codes not allowlisted (publish)"
  ipset list -n | grep -qx t3-tunnel && bad "ipset t3-tunnel exists with T3_CONNECT=publish" || ok "no t3-tunnel ipset (publish)"
  grep -q argotunnel "$conf" && bad "dnsmasq config mentions argotunnel with T3_CONNECT=publish" || ok "no argotunnel.com in dnsmasq (publish)"
  iptables -S OUTPUT | grep -q -- '--dport 7844' && bad "a 7844 rule exists with T3_CONNECT=publish" || ok "no 7844 rule (publish)"
else
  grep -q argotunnel "$conf" && bad "dnsmasq config mentions argotunnel with T3 Connect off" || ok "no argotunnel.com in dnsmasq (T3 Connect off)"
  grep -q 't3\.codes' "$conf" && bad "dnsmasq config mentions t3.codes with T3 Connect off" || ok "no t3.codes in dnsmasq (T3 Connect off)"
  ipset list -n | grep -qx t3-tunnel && bad "ipset t3-tunnel exists with T3 Connect off" || ok "no t3-tunnel ipset (T3 Connect off)"
fi

# --- FTP: the raw table holds our helper chain ONLY when on; its set is filled only from the FTP hosts ---
raw_rules=$(iptables-save -t raw 2>&1 | grep -E '^(-A|:)' || true)
if [ "$EXPECT_FTP" = 1 ]; then
  # Compared as sorted sets: iptables-save's chain order is the backend's (legacy vs nft), not ours.
  expect_raw=$(printf '%s\n' ':PREROUTING ACCEPT' ':OUTPUT ACCEPT' ':AGENT_FTP -' '-A OUTPUT -j AGENT_FTP' \
    '-A AGENT_FTP -p tcp -m tcp --dport 21 -m set --match-set ftp-hosts dst -j CT --helper ftp' | sort)
  got_raw=$(sed -E 's/ \[[0-9]+:[0-9]+\]$//' <<<"$raw_rules" | sort)
  if [ "$got_raw" = "$expect_raw" ]; then ok "raw table: exactly the AGENT_FTP jump + the ftp helper rule"
  else bad "raw table differs (- expected, + actual):"; diff <(echo "$expect_raw") <(echo "$got_raw") | sed 's/^/        /'; fi
  ipset list -n | grep -qx ftp-hosts && ok "ipset ftp-hosts exists" || bad "no ipset ftp-hosts"
  grep -Eq '^ipset=/[^/]+/(allowed-domains,)?ftp-hosts$' "$conf" && ok "dnsmasq fills ftp-hosts" || bad "no dnsmasq ipset= line for ftp-hosts"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ "$(grep -c "^ipset=/$d/" "$conf")" = 1 ] && ok "dnsmasq: exactly one ipset= line for FTP host $d" || bad "dnsmasq: not exactly one ipset= line for FTP host $d"
  done < <(sed 's/#.*//; s/[[:space:]]//g' /etc/firewall/ftp-hosts | tr 'A-Z' 'a-z')
else
  ! grep -q -- 'AGENT_FTP' <<<"$raw_rules" && ok "raw table: no AGENT_FTP chain (FTP off)" || bad "raw table has AGENT_FTP with FTP off"
  ! grep -q -- '--helper' <<<"$raw_rules" && ok "raw table: no helper rule (FTP off)" || bad "raw table has a helper rule with FTP off"
  ipset list -n | grep -qx ftp-hosts && bad "ipset ftp-hosts exists with FTP off" || ok "no ftp-hosts ipset (FTP off)"
  grep -q ftp-hosts "$conf" && bad "dnsmasq config names ftp-hosts with FTP off" || ok "no ftp-hosts in dnsmasq (FTP off)"
fi
[ "$fail" -eq 0 ] && echo "FIREWALL: ALL PASSED" || { echo "FIREWALL: FAILURES"; exit 1; }
