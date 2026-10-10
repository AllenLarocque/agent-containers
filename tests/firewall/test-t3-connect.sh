#!/usr/bin/env bash
# Run INSIDE a started container AS THE AGENT USER (uid 1000), AFTER init-firewall.sh.
# T3 Connect (owner opt-in, spec §13.1): with the switch ON, t3.codes resolves and cloudflared reaches
# Cloudflare's tunnel edge on 7844 (UDP/QUIC and TCP/HTTP2), and 7844 stays closed to every other
# host; with it OFF, none of that works. Root-side checks (exact rules, ipset contents) live in
# test-firewall.sh (EXPECT_T3_CONNECT).
# Env: MODE      on | off
#      EDGE_IP   a tunnel-edge IPv4 (region1.v2.argotunnel.com) that the CI step proved reachable on
#                TCP 7844 from the runner, so a block here is the firewall (not a dead edge)
#      ANNOTATE  =1 in CI: also print failures as ::error:: annotations (CI logs are not readable
#                from the agent containers; annotations are)
set -uo pipefail
fail=0
ok(){ echo "OK:   $*"; }
bad(){ echo "FAIL: $*"; fail=1; [ "${ANNOTATE:-0}" != 1 ] || echo "::error title=T3 Connect ($MODE)::$*"; }
: "${MODE:?MODE must be on or off}" "${EDGE_IP:?EDGE_IP must be set}"
[ "$(id -u)" = 1000 ] && ok "running as uid 1000 ($(id -un))" || bad "must run as the agent (uid 1000), not $(id -u)"
A_RE='^[0-9]+(\.[0-9]+){3}$'
SRV=_v2-origintunneld._tcp.argotunnel.com
srv_targets(){ dig @127.0.0.1 SRV "$SRV" +short +time=3 +tries=2 2>/dev/null | awk '{print $4}'; }
a_of(){ dig @127.0.0.1 "$1" A +short +time=3 +tries=2 2>/dev/null | grep -E "$A_RE"; }
# TCP connect; prints the error text. A locally REJECTed SYN fails at once with "No route to host"
# (icmp-admin-prohibited), so "refused" or a timeout would mean the packet left the container.
tcp_err(){ { timeout "$1" bash -c "</dev/tcp/$2/$3" >/dev/null; } 2>&1; }   # prints only the error text
rejected_here(){ # $1 ip, $2 port, $3 label
  local e rc
  e=$(tcp_err 8 "$1" "$2"); rc=$?
  if [ "$rc" -ne 0 ] && grep -Eq 'No route to host|Operation not permitted' <<<"$e"; then ok "$3: rejected by the firewall"
  elif [ "$rc" -eq 0 ]; then bad "$3: CONNECTED"
  else bad "$3: failed, but not by the firewall (rc=$rc: $e)"; fi
}

# A non-tunnel allowlisted host: never 7844, in either mode.
GH_IP=$(a_of api.github.com | head -n 1)
if [ -n "$GH_IP" ]; then rejected_here "$GH_IP" 7844 "allowlisted api.github.com ($GH_IP) on TCP 7844"
else bad "api.github.com does not resolve"; fi

# cloudflared, pinned to what T3 v0.0.45 itself downloads (packages/shared/src/relayClient.ts).
# A token for a tunnel that does not exist: reaching the edge = an error FROM THE SERVER SIDE. Over
# QUIC the edge drops the registration as a control-stream failure, which only happens on an
# ESTABLISHED QUIC connection (a blocked dial logs "failed to dial to edge with quic" instead).
CF_URL=https://github.com/cloudflare/cloudflared/releases/download/2026.5.2/cloudflared-linux-amd64
CF_SHA=5286698547f03df745adb2355f04c12dde52ef425491e81f433642d695521886
CF=$(mktemp -d)/cloudflared
if curl -q -fsSL --max-time 120 -o "$CF" "$CF_URL" && echo "$CF_SHA  $CF" | sha256sum -c - >/dev/null 2>&1; then
  chmod +x "$CF"; ok "cloudflared 2026.5.2 downloaded (github release, sha256 verified)"
else
  bad "could not download/verify cloudflared"; CF=
fi
FAKE_TOKEN=$(printf '{"a":"%s","t":"%s","s":"%s"}' "$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')" \
  "$(cat /proc/sys/kernel/random/uuid)" "$(head -c 32 /dev/urandom | base64 -w0)" | base64 -w0)
EDGE_RESPONSE='error from server side|Unauthorized|[Ii]nvalid tunnel|[Tt]unnel not found|control stream encountered a failure'
run_cloudflared(){ # $1 protocol -> its log
  timeout "${2:-45}" "$CF" tunnel --no-autoupdate --protocol "$1" --loglevel debug run --token "$FAKE_TOKEN" 2>&1
}

if [ "$MODE" = on ]; then
  # SRV through dnsmasq (cloudflared's edge discovery), then the targets' A records.
  mapfile -t targets < <(srv_targets)
  [ "${#targets[@]}" -gt 0 ] && ok "SRV $SRV answers via dnsmasq: ${targets[*]}" || bad "SRV $SRV gives no answer via dnsmasq"
  EIP=""
  for t in "${targets[@]}"; do ip=$(a_of "$t" | head -n 1); [ -n "$ip" ] && { EIP=$ip; break; }; done
  [ -n "$EIP" ] && ok "SRV target resolves ($EIP)" || { bad "no SRV target resolves"; EIP=$EDGE_IP; }
  e=$(tcp_err 10 "$EIP" 7844) && ok "TCP $EIP:7844 (tunnel edge, HTTP2 transport) connects" || bad "TCP $EIP:7844 blocked: $e"
  rejected_here "$EIP" 443 "tunnel edge $EIP on TCP 443 (t3-tunnel gets 7844 only)"
  for h in app.t3.codes relay.t3.codes clerk.t3.codes; do
    [ -n "$(a_of "$h")" ] && ok "$h resolves" || bad "$h does not resolve"
  done
  code=$(curl -q -s -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 20 https://app.t3.codes/ 2>/dev/null)
  [ -n "$code" ] && [ "$code" != 000 ] && ok "HTTPS to app.t3.codes answers (HTTP $code)" || bad "HTTPS to app.t3.codes failed"
  if [ -n "$CF" ]; then
    for proto in quic http2; do
      log=$(run_cloudflared "$proto")
      if grep -Eq "$EDGE_RESPONSE" <<<"$log"; then ok "cloudflared --protocol $proto reached the edge (it rejected the fake token)"
      else bad "cloudflared --protocol $proto got no answer from the edge. Last lines: $(tail -n 8 <<<"$log" | tr '\n' '|' | cut -c1-900)"; fi
    done
  fi
else
  st=$(dig @127.0.0.1 SRV "$SRV" +time=3 +tries=2 2>/dev/null | sed -n 's/.*status: \([A-Z]*\).*/\1/p' | head -1)
  case "$st" in REFUSED|NXDOMAIN) ok "SRV $SRV is $st (argotunnel.com not resolvable)";; *) bad "SRV $SRV status '$st', want REFUSED/NXDOMAIN";; esac
  [ -z "$(a_of app.t3.codes)" ] && ok "app.t3.codes does not resolve" || bad "app.t3.codes resolves with T3 Connect off"
  rejected_here "$EDGE_IP" 7844 "tunnel edge $EDGE_IP (literal) on TCP 7844"
  if [ -n "$CF" ]; then
    log=$(run_cloudflared quic 30)
    if grep -Eq "$EDGE_RESPONSE" <<<"$log"; then bad "cloudflared reached the edge with T3 Connect OFF"
    else ok "cloudflared cannot reach the edge (no server-side answer)"; fi
  fi
fi
[ "$fail" -eq 0 ] && echo "T3-CONNECT($MODE): ALL PASSED" || { echo "T3-CONNECT($MODE): FAILURES"; exit 1; }
