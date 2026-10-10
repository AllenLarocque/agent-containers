#!/usr/bin/env bash
# Run INSIDE a started container AS THE AGENT USER (uid 1000), AFTER init-firewall.sh.
# Proves the confinement from the agent's side: no port-22 bypass, no direct DNS to any resolver
# (public, upstream, or Docker's 127.0.0.11), dnsmasq answers ONLY allowlisted names, and the agent
# cannot edit the firewall's inputs.
# Env: EXPECT_UPSTREAM     the container's original resolver (captured before the firewall ran)
#      SSH_PROBE_IP        optional: a NON-allowlisted IP that really listens on TCP 22 (the CI step
#                          proves it is reachable from the runner, so a block here is the firewall)
#      REQUIRE_DOCKER_DNS  =1 on a user-defined (compose-like) network: 127.0.0.11 must exist and be blocked
set -uo pipefail
fail=0
ok(){ echo "OK:   $*"; }; bad(){ echo "FAIL: $*"; fail=1; }
: "${EXPECT_UPSTREAM:?EXPECT_UPSTREAM must be set}"
[ "$(id -u)" = 1000 ] && ok "running as uid 1000 ($(id -un))" || bad "must run as the agent (uid 1000), not $(id -u)"
A_RE='^[0-9]+(\.[0-9]+){3}$'
answers(){ dig "$@" +short +time=2 +tries=1 2>/dev/null | grep -E "$A_RE"; }   # prints A records, rc 0 iff any
status(){ dig "$@" +time=3 +tries=2 2>/dev/null | sed -n 's/.*status: \([A-Z]*\).*/\1/p' | head -1; }
tcp(){ timeout "$1" bash -c "</dev/tcp/$2/$3" 2>/dev/null; }

# --- C1: no "TCP 22 to anywhere" ---
tcp 5 1.1.1.1 22 && bad "TCP 1.1.1.1:22 connected" || ok "TCP 1.1.1.1:22 blocked"
if [ -n "${SSH_PROBE_IP:-}" ]; then
  tcp 8 "$SSH_PROBE_IP" 22 && bad "TCP $SSH_PROBE_IP:22 (non-allowlisted, listening) connected: port-22 bypass" \
    || ok "TCP $SSH_PROBE_IP:22 (non-allowlisted, listening) blocked"
fi
tcp 10 github.com 22 && ok "TCP github.com:22 (allowlisted) connects" || bad "TCP github.com:22 blocked, SSH to GitHub broken"

# --- C2: no UDP/TCP 53 except dnsmasq's own upstream queries ---
answers @1.1.1.1 example.com A >/dev/null && bad "UDP DNS to 1.1.1.1 answered" || ok "UDP DNS to 1.1.1.1 blocked"
answers +tcp @1.1.1.1 example.com A >/dev/null && bad "TCP DNS to 1.1.1.1 answered" || ok "TCP DNS to 1.1.1.1 blocked"
answers @"$EXPECT_UPSTREAM" example.com A >/dev/null && bad "agent queried the upstream $EXPECT_UPSTREAM directly (UDP)" \
  || ok "agent cannot query the upstream $EXPECT_UPSTREAM (UDP)"
answers +tcp @"$EXPECT_UPSTREAM" example.com A >/dev/null && bad "agent queried the upstream $EXPECT_UPSTREAM directly (TCP)" \
  || ok "agent cannot query the upstream $EXPECT_UPSTREAM (TCP)"

# --- I1: dnsmasq forwards ONLY allowlisted names ---
answers @127.0.0.1 api.github.com A >/dev/null && ok "dnsmasq answers api.github.com" || bad "dnsmasq gives no answer for api.github.com"
answers @127.0.0.1 github.com A >/dev/null && ok "dnsmasq answers github.com" || bad "dnsmasq gives no answer for github.com"
answers @127.0.0.1 cloud.r-project.org A >/dev/null && ok "dnsmasq answers cloud.r-project.org" || bad "dnsmasq gives no answer for cloud.r-project.org"
answers @127.0.0.1 example.com A >/dev/null && bad "dnsmasq answered example.com (non-allowlisted)" || ok "dnsmasq gives no A for example.com"
st=$(status @127.0.0.1 example.com A)
case "$st" in REFUSED|NXDOMAIN) ok "dnsmasq status for example.com is $st";; *) bad "dnsmasq status for example.com is '$st', want REFUSED/NXDOMAIN";; esac
[ -n "$(dig @127.0.0.1 tunnel-probe.example.org TXT +short +time=2 +tries=1 2>/dev/null)" ] && bad "dnsmasq answered a TXT query for a non-allowlisted name" \
  || ok "dnsmasq gives no TXT answer for a non-allowlisted name"
getent ahostsv4 example.com >/dev/null && bad "system resolver resolved example.com" || ok "system resolver cannot resolve example.com"

# --- I1: Docker's embedded resolver is not a side door ---
if [ "${REQUIRE_DOCKER_DNS:-0}" = 1 ]; then
  [ "$EXPECT_UPSTREAM" = 127.0.0.11 ] && ok "compose-like network: original resolver is 127.0.0.11" \
    || bad "REQUIRE_DOCKER_DNS=1 but the original resolver is $EXPECT_UPSTREAM (not a user-defined network)"
  answers @127.0.0.11 example.com A >/dev/null && bad "agent queried Docker DNS 127.0.0.11 (UDP)" || ok "Docker DNS 127.0.0.11 blocked for the agent (UDP)"
  answers +tcp @127.0.0.11 example.com A >/dev/null && bad "agent queried Docker DNS 127.0.0.11 (TCP)" || ok "Docker DNS 127.0.0.11 blocked for the agent (TCP)"
fi

# --- egress as the agent ---
if curl --connect-timeout 10 -sSf https://api.github.com/zen >/dev/null 2>&1; then ok "agent reaches api.github.com"; else bad "agent cannot reach api.github.com"; fi
if curl --connect-timeout 10 -sSf https://cloud.r-project.org/src/contrib/PACKAGES.gz >/dev/null 2>&1; then ok "agent reaches CRAN"; else bad "agent cannot reach CRAN"; fi
if curl --connect-timeout 5 -s https://1.1.1.1/ >/dev/null 2>&1; then bad "agent reached https://1.1.1.1/"; else ok "agent blocked from https://1.1.1.1/"; fi

# --- I2b: the agent cannot change the firewall's inputs ---
for f in /etc/firewall/allowlist.d/*.txt; do
  ( : >> "$f" ) 2>/dev/null && bad "agent can write $f" || ok "agent cannot write $f"
done
( : > /etc/firewall/allowlist.d/99-agent.txt ) 2>/dev/null && bad "agent can add a file to /etc/firewall/allowlist.d" || ok "agent cannot add allowlist files"
# The T3 Connect switch: absent (off) the agent cannot create it; mounted (on) it cannot change it.
( : >> /etc/firewall/t3-connect ) 2>/dev/null && bad "agent can create or write /etc/firewall/t3-connect" || ok "agent cannot create or write the T3 Connect switch"
( : > /etc/firewall/agent-probe ) 2>/dev/null && bad "agent can create files in /etc/firewall" || ok "agent cannot create files in /etc/firewall"
( : >> /etc/dnsmasq.d/allowlist.conf ) 2>/dev/null && bad "agent can write the dnsmasq config" || ok "agent cannot write the dnsmasq config"
( : >> /run/firewall-upstream ) 2>/dev/null && bad "agent can write /run/firewall-upstream" || ok "agent cannot write /run/firewall-upstream"
( : >> /etc/resolv.conf ) 2>/dev/null && bad "agent can write /etc/resolv.conf" || ok "agent cannot write /etc/resolv.conf"
[ "$fail" -eq 0 ] && echo "AGENT-EGRESS: ALL PASSED" || { echo "AGENT-EGRESS: FAILURES"; exit 1; }
