#!/usr/bin/env bash
# Run INSIDE a started container AS ROOT, AFTER `sudo init-firewall.sh` with /etc/firewall/profile
# mounted read-only saying PROFILE=research (the shared research container, spec §2.1). Egress checks
# run as the agent (uid 1000) via setpriv; rule snapshots need root.
# Research: open to PUBLIC IPv4 on any TCP/UDP port, any name resolves; private, shared (CGNAT/Tailscale),
# link-local (metadata), loopback, reserved ranges, the gateway (host) and its own networks are REJECTED.
# Env: EXPECT_UPSTREAM  the container's original resolver (captured before the firewall ran)
#      EDGE_IP          a public IPv4 that the CI step proved reachable on TCP 7844 from the runner
#                       (an odd port: open here, closed for builders)
#      ANNOTATE         =1 in CI: failures also as ::error:: annotations (CI logs are not readable remotely)
set -uo pipefail
fail=0
ok(){ echo "OK:   $*"; }
bad(){ echo "FAIL: $*"; fail=1; [ "${ANNOTATE:-0}" != 1 ] || echo "::error title=research firewall::$*"; }
: "${EXPECT_UPSTREAM:?EXPECT_UPSTREAM must be set}" "${EDGE_IP:?EDGE_IP must be set}"
[ "$(id -u)" = 0 ] || { echo "FAIL: run as root"; exit 1; }
AGENT=(setpriv --reuid=1000 --regid=1000 --clear-groups --reset-env)
as_agent(){ "${AGENT[@]}" "$@"; }
# Reachable = any HTTP answer (code != 000): the firewall let DNS+TCP+TLS through. An HTTP error (rate limit,
# a 5xx) is the site's answer, not a block; `curl -f` counted it as blocked and CI failed at random. One retry.
# On failure REACH_CODE = "<http code> <ip tried> exit <curl exit>" (6 DNS, 7 refused, 28 timeout, 35/60 TLS).
reach(){ local c rc i; for i in 1 2; do c=$(as_agent curl -q -s -o /dev/null -w '%{http_code} %{remote_ip}' --connect-timeout 10 --max-time 30 "$1" 2>/dev/null); rc=$?; [ -n "$c" ] && [ "${c%% *}" != 000 ] && return 0; [ "$i" = 1 ] && sleep 3; done; REACH_CODE="${c:-000} exit $rc"; return 1; }
A_RE='^[0-9]+(\.[0-9]+){3}$'
tcp_err(){ { timeout "$1" bash -c "</dev/tcp/$2/$3" >/dev/null; } 2>&1; }
rejected_here(){ # $1 ip, $2 port, $3 label: a locally REJECTed SYN fails at once with "No route to host"
  local e rc
  e=$(as_agent bash -c "{ timeout 8 bash -c '</dev/tcp/$1/$2' >/dev/null; } 2>&1"); rc=$?
  if [ "$rc" -ne 0 ] && grep -Eq 'No route to host|Operation not permitted' <<<"$e"; then ok "$3: rejected by the firewall"
  elif [ "$rc" -eq 0 ]; then bad "$3: CONNECTED"
  else bad "$3: failed, but not by the firewall (rc=$rc: $e)"; fi
}

# --- EXACT rule snapshot ---
DUID=$(id -u dnsmasq)
GW=$(ip -4 route show default | awk '{print $3; exit}')
own=$(ip -4 route show scope link | awk '{print "-A OUTPUT -d " $1 " -j REJECT --reject-with icmp-admin-prohibited"}' | sort -u)
expect_v4=$(sed -e "s|@UP@|$EXPECT_UPSTREAM|g" -e "s|@DUID@|$DUID|g" -e "s|@GW@|$GW|g" <<'SNAP'
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
-A OUTPUT -d 0.0.0.0/8 -j REJECT --reject-with icmp-admin-prohibited
-A OUTPUT -d 10.0.0.0/8 -j REJECT --reject-with icmp-admin-prohibited
-A OUTPUT -d 100.64.0.0/10 -j REJECT --reject-with icmp-admin-prohibited
-A OUTPUT -d 127.0.0.0/8 -j REJECT --reject-with icmp-admin-prohibited
-A OUTPUT -d 169.254.0.0/16 -j REJECT --reject-with icmp-admin-prohibited
-A OUTPUT -d 172.16.0.0/12 -j REJECT --reject-with icmp-admin-prohibited
-A OUTPUT -d 192.0.0.0/24 -j REJECT --reject-with icmp-admin-prohibited
-A OUTPUT -d 192.168.0.0/16 -j REJECT --reject-with icmp-admin-prohibited
-A OUTPUT -d 198.18.0.0/15 -j REJECT --reject-with icmp-admin-prohibited
-A OUTPUT -d 224.0.0.0/4 -j REJECT --reject-with icmp-admin-prohibited
-A OUTPUT -d 240.0.0.0/4 -j REJECT --reject-with icmp-admin-prohibited
@OWN@
-A OUTPUT -d @GW@/32 -j REJECT --reject-with icmp-admin-prohibited
-A OUTPUT -p tcp -j ACCEPT
-A OUTPUT -p udp -j ACCEPT
-A OUTPUT -j REJECT --reject-with icmp-admin-prohibited
SNAP
)
expect_v4=${expect_v4/@OWN@/$own}
got_v4=$(iptables -S 2>&1)
if [ "$got_v4" = "$expect_v4" ]; then ok "iptables -S equals the research snapshot"
else bad "iptables -S differs from the research snapshot"; diff <(echo "$expect_v4") <(echo "$got_v4") | sed 's/^/        /'
  [ "${ANNOTATE:-0}" != 1 ] || echo "::error title=research snapshot diff::$(diff <(echo "$expect_v4") <(echo "$got_v4") | awk '{printf "%s%%0A", $0}')"; fi
if got_v6=$(ip6tables -S 2>&1); then
  want_v6=$'-P INPUT DROP\n-P FORWARD DROP\n-P OUTPUT DROP\n-A INPUT -i lo -j ACCEPT\n-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT\n-A OUTPUT -o lo -j ACCEPT\n-A OUTPUT -m state --state RELATED,ESTABLISHED -j ACCEPT'
  [ "$got_v6" = "$want_v6" ] && ok "ip6tables: default-deny, as for builders" || bad "ip6tables differs: $got_v6"
fi
conf=/etc/dnsmasq.d/allowlist.conf
[ "$(grep -c '^server=' "$conf")" = 1 ] && grep -qx "server=$EXPECT_UPSTREAM" "$conf" && ok "dnsmasq: one default server (any name), the original resolver" \
  || bad "dnsmasq config is not the research one: $(tr '\n' '|' < "$conf")"
grep -q '^ipset=' "$conf" && bad "dnsmasq research config has ipset= lines" || ok "dnsmasq research config has no ipset= lines"

# --- as the agent: open public egress, any name, any port (TCP + UDP) ---
[ -n "$(as_agent dig @127.0.0.1 example.com A +short +time=3 +tries=2 | grep -E "$A_RE")" ] && ok "dnsmasq resolves non-allowlisted example.com" || bad "example.com does not resolve"
reach https://example.com/ && ok "agent reaches https://example.com (443, not allowlisted)" || bad "agent cannot reach https://example.com (curl: $REACH_CODE)"
as_agent curl -q -sS -o /dev/null --max-time 20 https://1.1.1.1/ && ok "agent reaches https://1.1.1.1 (literal public IP)" || bad "agent cannot reach https://1.1.1.1"
e=$(as_agent bash -c "{ timeout 10 bash -c '</dev/tcp/$EDGE_IP/7844' >/dev/null; } 2>&1") && ok "agent reaches $EDGE_IP:7844 (an odd TCP port)" || bad "agent cannot reach $EDGE_IP:7844: $e"
[ -n "$(as_agent dig @1.1.1.1 example.com A +short +time=3 +tries=2 | grep -E "$A_RE")" ] && ok "agent reaches UDP 53 at 1.1.1.1 directly (UDP open to public IPs)" || bad "UDP to 1.1.1.1:53 blocked"

# --- as the agent: everything private, local or reserved is rejected HERE ---
rejected_here 10.1.2.3 443 "10.0.0.0/8 (RFC1918)"
rejected_here 172.16.5.5 443 "172.16.0.0/12 (RFC1918)"
rejected_here 192.168.1.1 80 "192.168.0.0/16 (RFC1918, home LAN)"
rejected_here 100.64.1.1 443 "100.64.0.0/10 (CGNAT, Tailscale)"
rejected_here 100.100.100.100 53 "100.100.100.100 (Tailscale MagicDNS)"
rejected_here 169.254.169.254 80 "169.254.169.254 (cloud metadata)"
rejected_here 198.18.0.1 443 "198.18.0.0/15 (benchmarking)"
rejected_here 240.0.0.1 443 "240.0.0.0/4 (reserved)"
rejected_here 0.0.0.1 443 "0.0.0.0/8"
rejected_here "$GW" 3773 "the gateway $GW (the Docker host)"
rejected_here "$GW" 22 "the gateway $GW on 22"
for n in $(ip -4 route show scope link | awk '{print $1}'); do
  sib=$(awk -F'[./]' '{printf "%d.%d.%d.%d", $1, $2, $3, $4+250}' <<<"$n")
  rejected_here "$sib" 80 "own network $n (a sibling container at $sib)"
done
# Docker's embedded resolver stays dnsmasq's alone; the upstream DNS rule is owner-matched as for builders
if [ "$EXPECT_UPSTREAM" = 127.0.0.11 ]; then
  [ -z "$(as_agent dig @127.0.0.11 example.com A +short +time=2 +tries=1 | grep -E "$A_RE")" ] && ok "agent cannot query Docker DNS 127.0.0.11" || bad "agent queried Docker DNS 127.0.0.11"
fi

# --- the switch is the owner's ---
( as_agent sh -c ': >> /etc/firewall/profile' ) 2>/dev/null && bad "agent can write /etc/firewall/profile" || ok "agent cannot write the profile switch"
out=$(setpriv --reuid=1000 --regid=1000 --init-groups env PROFILE=builder sudo /usr/local/bin/init-firewall.sh 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q '^Profile: research' <<<"$out" && ok "an agent re-run (PROFILE=builder in its env) stays research" || bad "agent re-run: rc=$rc, $(tail -n 3 <<<"$out" | tr '\n' '|')"
[ "$fail" -eq 0 ] && echo "RESEARCH-FIREWALL: ALL PASSED" || { echo "RESEARCH-FIREWALL: FAILURES"; exit 1; }
