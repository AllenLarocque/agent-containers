#!/usr/bin/env bash
# Run INSIDE a started container AS ROOT (NET_ADMIN/NET_RAW), WITHOUT an /etc/firewall/ftp-hosts mount:
# this test writes that file itself (as test-invalid-token.sh writes its switches), so it can turn FTP
# on and off between firewall runs. FTP uploads (owner opt-in, decision 2026-10-11, spec §13.4): with
# the host list, tcp 21 opens to those hosts' addresses ONLY (ipset ftp-hosts) and the kernel's FTP
# conntrack helper is attached in the raw table, so the passive data connection leaves as RELATED; no
# port range is opened. Without it, nothing of that exists. The exact filter snapshot with FTP on is
# test-firewall.sh's (EXPECT_FTP=1, on a container with the read-only mount agent-up renders).
# Env: FTP_HOST  a public ANONYMOUS FTP server the CI step proved listable from the runner
#                (default ftp.ebi.ac.uk: EBI, the same organisation as ENA's webin2.ebi.ac.uk)
#      FTP_URL   a directory on it to list (default ftp://$FTP_HOST/pub/)
#      ANNOTATE  =1 in CI: also print failures as ::error:: annotations
set -uo pipefail
FTP_HOST=${FTP_HOST:-ftp.ebi.ac.uk}
FTP_URL=${FTP_URL:-ftp://$FTP_HOST/pub/}
F=/etc/firewall/ftp-hosts
EXTRA=/etc/firewall/allowlist.d/60-ftp-test.txt
FW=/usr/local/bin/init-firewall.sh
fail=0
ok(){ echo "OK:   $*"; }
bad(){ echo "FAIL: $*"; fail=1; [ "${ANNOTATE:-0}" != 1 ] || echo "::error title=FTP firewall::$*"; }
[ "$(id -u)" = 0 ] || { bad "must run as root (it rewrites $F and re-runs the firewall)"; exit 1; }
as_agent(){ setpriv --reuid=1000 --regid=1000 --init-groups env HOME=/home/agent "$@"; }
A_RE='^[0-9]+(\.[0-9]+){3}$'
ips_of(){ dig -r +short +time=3 +tries=2 "$1" A @127.0.0.1 2>/dev/null | grep -E "$A_RE"; }
# TCP connect AS THE AGENT; a locally REJECTed SYN fails at once with "No route to host"
# (icmp-admin-prohibited), so "refused" or a timeout would mean the packet left the container.
rejected_here(){ # $1 ip, $2 port, $3 label
  local e rc
  e=$( { as_agent timeout 8 bash -c "</dev/tcp/$1/$2" >/dev/null; } 2>&1 ); rc=$?
  if [ "$rc" -ne 0 ] && grep -Eq 'No route to host|Operation not permitted' <<<"$e"; then ok "$3: rejected by the firewall"
  elif [ "$rc" -eq 0 ]; then bad "$3: CONNECTED"
  else bad "$3: failed, but not by the firewall (rc=$rc: $e)"; fi
}
not_rejected_here(){ # $1 ip, $2 port, $3 label: the SYN left the container (connected, refused or timed out remotely)
  local e rc
  e=$( { as_agent timeout 8 bash -c "</dev/tcp/$1/$2" >/dev/null; } 2>&1 ); rc=$?
  if [ "$rc" -ne 0 ] && grep -Eq 'No route to host|Operation not permitted' <<<"$e"; then bad "$3: rejected by the firewall"
  else ok "$3: not blocked by the firewall (rc=$rc)"; fi
}
# The live listing, as the agent, passive (curl tries EPSV, then PASV). Up to 3 attempts, so a single
# hiccup at EBI does not fail the run; a firewall that blocks the control or data channel fails all 3.
list_ftp(){ for _ in 1 2 3; do as_agent curl -q -sS --connect-timeout 10 --max-time 60 --list-only "$@" "$FTP_URL" >/tmp/ftp-list.out 2>/tmp/ftp-list.err && [ -s /tmp/ftp-list.out ] && return 0; sleep 3; done; return 1; }
# raw via iptables-save, minus its '# Generated/Completed ... on <date>' comments: those carry a timestamp,
# so an abort that crosses a second boundary would look like a change (CI run 38209981046, case [url]).
snap(){ { iptables -S; iptables -t nat -S; iptables-save -t raw | grep -v '^#'; ip6tables -S; ipset list -n; } 2>&1; }
run_fw(){ OUT=$("$FW" 2>&1); RC=$?; }
raw(){ iptables-save -t raw 2>/dev/null; }
n_of(){ grep -c -- "$1" || true; }   # stdin: count the lines containing $1
RULE_FILTER='-A OUTPUT -p tcp -m tcp --dport 21 -m set --match-set ftp-hosts dst -j ACCEPT'
RULE_RAW='-A AGENT_FTP -p tcp -m tcp --dport 21 -m set --match-set ftp-hosts dst -j CT --helper ftp'
JUMP_RAW='-A OUTPUT -j AGENT_FTP'

# ---- 0. the helper must be in the HOST kernel (CI: sudo modprobe nf_conntrack_ftp on the runner)
if [ ! -d /sys/module/nf_conntrack_ftp ]; then
  bad "nf_conntrack_ftp is not in this kernel: load it on the host first (sudo modprobe nf_conntrack_ftp)"
  echo "FTP: FAILURES"; exit 1
fi
ok "nf_conntrack_ftp present in the kernel"
rm -f "$F" "$EXTRA" /etc/firewall/profile

# ---- 1. a bad host list (or FTP on the research profile) aborts BEFORE any change
try_bad(){ # $1 label, $2 file content (printf format), $3 ERE the error must match, $4 profile file content (optional)
  printf "$2" > "$F"; [ -z "${4:-}" ] || printf "$4" > /etc/firewall/profile
  local before after; before=$(snap); run_fw; after=$(snap)
  rm -f "$F" /etc/firewall/profile
  [ "$RC" -ne 0 ] && ok "[$1] exit non-zero ($RC)" || bad "[$1] exited 0"
  grep -Eq "$3" <<<"$OUT" && ok "[$1] error: $(grep -m1 ERROR <<<"$OUT" | cut -c1-120)" || { bad "[$1] no matching error (/$3/):"; tail -n 5 <<<"$OUT"; }
  [ "$before" = "$after" ] && ok "[$1] iptables/raw/ip6tables/ipset untouched" || bad "[$1] firewall state changed"
}
try_bad "url"            'ftp://webin2.ebi.ac.uk\n'  "invalid FTP host in $F line 1"
try_bad "port"           'webin2.ebi.ac.uk:21\n'     "invalid FTP host in $F line 1"
try_bad "wildcard"       '*.ebi.ac.uk\n'             "invalid FTP host in $F line 1"
try_bad "second line"    'webin2.ebi.ac.uk\nbad host\n' "invalid FTP host in $F line 2"
try_bad "mid-line CR"    'webin2\rebi.ac.uk\n'       "invalid FTP host in $F line 1"
try_bad "empty file"     ''                          "names no host"
try_bad "comments only"  '# nothing\n\n'             "names no host"
try_bad "argotunnel.com" 'argotunnel.com\n'          "overlaps argotunnel.com"
try_bad "research"       'webin2.ebi.ac.uk\n'        "builder projects only" 'PROFILE=research\n'

# ---- 2. OFF: no host list -> no tcp 21 rule, nothing in raw, no ftp-hosts set
check_off(){ # $1 label
  local r; r=$(raw)
  grep -q '^FTP: off' <<<"$OUT" && ok "[$1] log says FTP: off" || bad "[$1] log does not say FTP: off"
  [ "$(iptables -S OUTPUT | grep -cE -- '--dport 21( |$)')" = 0 ] && ok "[$1] no tcp 21 rule in OUTPUT" || bad "[$1] a tcp 21 rule is in OUTPUT"
  ! grep -q -- 'AGENT_FTP' <<<"$r" && ok "[$1] no AGENT_FTP chain or jump in raw" || bad "[$1] AGENT_FTP is still in raw"
  ! grep -q -- '--helper ftp' <<<"$r" && ok "[$1] no ftp helper rule in raw" || bad "[$1] an ftp helper rule is in raw"
  ! ipset list -n | grep -qx ftp-hosts && ok "[$1] no ftp-hosts ipset" || bad "[$1] the ftp-hosts ipset exists"
  ! grep -q ftp-hosts /etc/dnsmasq.d/allowlist.conf && ok "[$1] dnsmasq fills no ftp-hosts set" || bad "[$1] dnsmasq still names ftp-hosts"
}
run_fw
[ "$RC" -eq 0 ] && ok "firewall without a host list: exit 0" || { bad "firewall without a host list failed ($RC)"; tail -n 5 <<<"$OUT"; }
check_off "off"

# ---- 3. ON, the FTP host NOT on the allowlist (ENA's case: webin2 is only an upload server)
check_on(){ # $1 label
  local r; r=$(raw)
  grep -q "^FTP: ON (hosts $FTP_HOST; tcp 21 + conntrack ftp helper)" <<<"$OUT" && ok "[$1] log says FTP: ON for $FTP_HOST" || bad "[$1] no 'FTP: ON (hosts $FTP_HOST; ...' line"
  [ "$(iptables -S OUTPUT | n_of "$RULE_FILTER")" = 1 ] && ok "[$1] exactly one tcp 21 ACCEPT, to the ftp-hosts set" || bad "[$1] the tcp 21 ftp-hosts ACCEPT is missing or doubled"
  [ "$(iptables -S OUTPUT | grep -cE -- '--dport 21( |$)')" = 1 ] && ok "[$1] no other tcp 21 rule" || bad "[$1] more than one tcp 21 rule"
  [ "$(grep -cxF -- "$JUMP_RAW" <<<"$r")" = 1 ] && ok "[$1] raw OUTPUT jumps to AGENT_FTP exactly once" || bad "[$1] raw OUTPUT -> AGENT_FTP jump missing or doubled"
  [ "$(grep -cxF -- "$RULE_RAW" <<<"$r")" = 1 ] && [ "$(grep -c -- '--helper' <<<"$r")" = 1 ] \
    && ok "[$1] exactly one helper rule: ftp, tcp 21, ftp-hosts only" || { bad "[$1] raw helper rule wrong:"; sed 's/^/        /' <<<"$r"; }
  ipset list -n | grep -qx ftp-hosts && ok "[$1] ipset ftp-hosts exists" || bad "[$1] no ipset ftp-hosts"
}
printf '# ENA-like upload host (CRLF line, mixed case, inline comment)\r\n%s  # comment\n' "${FTP_HOST^^}" > "$F"
run_fw
[ "$RC" -eq 0 ] && ok "firewall with a host list: exit 0" || { bad "firewall with a host list failed ($RC)"; tail -n 8 <<<"$OUT"; }
check_on "on"
conf=/etc/dnsmasq.d/allowlist.conf
grep -qx "ipset=/$FTP_HOST/ftp-hosts" "$conf" && ok "dnsmasq: $FTP_HOST addresses go to ftp-hosts ONLY" || bad "no ipset=/$FTP_HOST/ftp-hosts line"
grep -q "^server=/$FTP_HOST/" "$conf" && ok "dnsmasq forwards $FTP_HOST" || bad "no server=/$FTP_HOST/ line"
mapfile -t FIPS < <(ips_of "$FTP_HOST")
[ "${#FIPS[@]}" -gt 0 ] && ok "$FTP_HOST resolves via dnsmasq: ${FIPS[*]}" || bad "$FTP_HOST does not resolve via dnsmasq"
for ip in "${FIPS[@]}"; do
  ipset test ftp-hosts "$ip" 2>/dev/null && ok "$ip is in ftp-hosts" || bad "$ip is NOT in ftp-hosts"
  ipset test allowed-domains "$ip" 2>/dev/null && bad "$ip is in allowed-domains (22/80/443) although $FTP_HOST is not allowlisted" || ok "$ip is not in allowed-domains"
done
if [ "${#FIPS[@]}" -gt 0 ]; then
  rejected_here "${FIPS[0]}" 443 "FTP host ${FIPS[0]} on tcp 443 (ftp-hosts gets 21 only)"
  rejected_here "${FIPS[0]}" 50000 "FTP host ${FIPS[0]} on a high port without an FTP expectation (no port range)"
fi
GH_IP=$(ips_of api.github.com | head -n 1)
[ -n "$GH_IP" ] && rejected_here "$GH_IP" 21 "allowlisted api.github.com ($GH_IP) on tcp 21 (not an FTP host)" || bad "api.github.com does not resolve"
# THE end-to-end proof, and deliberately HARD (unlike the soft CRAN/T3-edge checks in init-firewall.sh,
# which must not brick a container start): it is the only check that the tcp 21 rule AND the helper's
# RELATED data channel work together, and the listing arrives ONLY over the passive data connection.
# The CI step first proves the runner itself can list the same URL, so a failure here is the firewall.
if list_ftp; then ok "agent lists $FTP_URL (passive: control on 21 + the RELATED data connection)"
else bad "agent cannot list $FTP_URL: $(tr '\n' ' ' </tmp/ftp-list.err | cut -c1-300)"; fi
# The control connection really carried the helper (its conntrack entry lingers in TIME_WAIT).
conntrack -L -p tcp --dport 21 2>/dev/null | grep -q 'helper=ftp' && ok "the tcp 21 connection was tracked with helper=ftp" \
  || bad "no tcp 21 conntrack entry with helper=ftp"
# PASV only (no EPSV): informational. The helper only expects a PASV data connection to the address
# the server announces; a server behind NAT that announces another one cannot work this way.
if list_ftp --disable-epsv; then echo "NOTE: PASV-only listing works too"; else echo "NOTE: PASV-only listing failed (EPSV is what curl uses first): $(tr '\n' ' ' </tmp/ftp-list.err | cut -c1-200)"; fi

# ---- 4. idempotent re-run: still exactly one of each
run_fw
[ "$RC" -eq 0 ] && ok "re-run with FTP on: exit 0" || { bad "re-run with FTP on failed ($RC)"; tail -n 8 <<<"$OUT"; }
check_on "re-run"

# ---- 5. ON, and the same host ALSO allowlisted: ONE dnsmasq line names both sets
printf '%s\n' "$FTP_HOST" > "$EXTRA"
run_fw
[ "$RC" -eq 0 ] && ok "firewall with $FTP_HOST allowlisted too: exit 0" || { bad "firewall with $FTP_HOST allowlisted too failed ($RC)"; tail -n 8 <<<"$OUT"; }
check_on "allowlisted too"
[ "$(grep -c "^ipset=/$FTP_HOST/" "$conf")" = 1 ] && grep -qx "ipset=/$FTP_HOST/allowed-domains,ftp-hosts" "$conf" \
  && ok "dnsmasq: one ipset= line for $FTP_HOST naming allowed-domains AND ftp-hosts" || bad "dnsmasq ipset= lines for $FTP_HOST: $(grep "^ipset=/$FTP_HOST/" "$conf" | tr '\n' ' ')"
mapfile -t FIPS < <(ips_of "$FTP_HOST")
for ip in "${FIPS[@]}"; do
  ipset test ftp-hosts "$ip" 2>/dev/null && ipset test allowed-domains "$ip" 2>/dev/null && ok "$ip is in both sets" || bad "$ip is not in both sets"
done
[ "${#FIPS[@]}" -gt 0 ] && not_rejected_here "${FIPS[0]}" 443 "allowlisted FTP host ${FIPS[0]} on tcp 443 (allowed-domains kept)"
list_ftp && ok "agent lists $FTP_URL (allowlisted too)" || bad "agent cannot list $FTP_URL (allowlisted too): $(tr '\n' ' ' </tmp/ftp-list.err | cut -c1-300)"

# ---- 6. OFF after ON (the host still allowlisted, so it resolves and 443 works): every FTP rule,
# the raw chain and the set are gone, and the SAME listing now FAILS: tcp 21 is closed again.
rm -f "$F"
run_fw
[ "$RC" -eq 0 ] && ok "re-run with FTP off again: exit 0" || { bad "re-run with FTP off failed ($RC)"; tail -n 8 <<<"$OUT"; }
check_off "off after on"
mapfile -t FIPS < <(ips_of "$FTP_HOST")
[ "${#FIPS[@]}" -gt 0 ] && ok "$FTP_HOST still resolves (allowlisted)" || bad "$FTP_HOST no longer resolves although allowlisted"
[ "${#FIPS[@]}" -gt 0 ] && rejected_here "${FIPS[0]}" 21 "allowlisted $FTP_HOST (${FIPS[0]}) on tcp 21 with FTP off"
if as_agent curl -q -sS --connect-timeout 10 --max-time 30 --list-only "$FTP_URL" >/dev/null 2>&1; then
  bad "agent lists $FTP_URL with FTP OFF"
else ok "agent cannot list $FTP_URL with FTP off"; fi
rm -f "$EXTRA"
run_fw   # leave the container as it started: no FTP, no test allowlist
[ "$fail" -eq 0 ] && echo "FTP: ALL PASSED" || { echo "FTP: FAILURES"; exit 1; }
