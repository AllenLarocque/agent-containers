#!/usr/bin/env bash
# Run INSIDE a container AS ROOT, BEFORE any firewall init, with the host's GitHub meta mounted
# read-only at /etc/firewall/github-meta.json (CI: one authenticated fetch on the runner, shared by the
# firewalled test containers, so they do not each spend the unauthenticated api.github.com limit).
#   MODE=good  a real meta file: the ranges come from it, with no live fetch and no temporary rules,
#              and the firewall comes up normally.
#   MODE=bad   a malformed file: init-firewall.sh aborts in its read-only phase, naming the file,
#              with iptables/ip6tables/ipset exactly as before (policies still ACCEPT, no rules).
set -uo pipefail
fail=0
ok(){ echo "OK:   $*"; }; bad(){ echo "FAIL: $*"; fail=1; }
MF=/etc/firewall/github-meta.json
MODE=${MODE:-}
case $MODE in good|bad) ;; *) echo "FAIL: MODE must be good or bad (got '$MODE')"; exit 1 ;; esac
[ -f "$MF" ] && ok "$MF is mounted" || { bad "$MF is not mounted (test not exercising the host-supplied meta)"; echo "META-FILE ($MODE): FAILURES"; exit 1; }
snap(){ { iptables -S; iptables -t nat -S; ip6tables -S; ipset list -n 2>/dev/null; } 2>&1; }

if [ "$MODE" = good ]; then
  out=$(timeout 300 /usr/local/bin/init-firewall.sh 2>&1); rc=$?
  echo "$out" | grep -v '^Adding GitHub range' | tail -n 8 | sed 's/^/        /'
  [ "$rc" -eq 0 ] && ok "init-firewall.sh exited 0" || bad "init-firewall.sh exited $rc with a valid meta file"
  grep -qF "GitHub meta: from $MF" <<<"$out" && ok "the ranges came from $MF" || bad "no 'GitHub meta: from $MF' line"
  grep -q 'Fetching GitHub IP ranges' <<<"$out" && bad "it fetched api.github.com/meta anyway" || ok "no live meta fetch"
  grep -q 'Temporary setup rules' <<<"$out" && bad "temporary setup rules were installed" || ok "no temporary setup rules"
  n=$(sed -n 's/^Added \([0-9][0-9]*\) GitHub range(s)$/\1/p' <<<"$out")
  [ -n "$n" ] && [ "$n" -gt 0 ] && ok "added $n GitHub range(s) from the file" || bad "no 'Added N GitHub range(s)' with N>0"
  # Non-vacuity: an address from the FILE's api ranges is in the ipset (not only what dnsmasq resolved).
  cidr=$(jq -r '.api[]' "$MF" | grep -Em1 '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$')
  if [ -n "$cidr" ]; then
    ipset test allowed-domains "${cidr%/*}" >/dev/null 2>&1 && ok "file range $cidr is in allowed-domains" || bad "file range $cidr is NOT in allowed-domains"
  else bad "no IPv4 api range in $MF"; fi
  left=$(iptables -S OUTPUT | grep -E -- '-d [0-9.]+/32 -p tcp -m tcp --dport 443 -j ACCEPT' || true)
  [ -z "$left" ] && ok "no per-IP 443 ACCEPT rule" || bad "unexpected per-IP 443 rule(s): $left"
  if curl -q -sS -o /dev/null --max-time 10 https://api.github.com/zen; then ok "https://api.github.com/zen reachable"
  else bad "https://api.github.com/zen NOT reachable with the file's ranges"; fi
else
  before=$(snap)
  out=$(timeout 300 /usr/local/bin/init-firewall.sh 2>&1); rc=$?
  after=$(snap)
  echo "$out" | tail -n 5 | sed 's/^/        /'
  [ "$rc" -ne 0 ] && ok "init-firewall.sh exited non-zero ($rc)" || bad "init-firewall.sh exited 0 with a malformed meta file"
  grep -E '^ERROR: .*github-meta\.json' <<<"$out" && ok "the error names github-meta.json" || bad "no ERROR line naming github-meta.json"
  grep -qE 'Fetching GitHub IP ranges|Temporary setup rules|GitHub meta: from' <<<"$out" && bad "it got past the read-only phase" || ok "aborted in the read-only phase"
  [ "$before" = "$after" ] && ok "iptables/ip6tables/ipset untouched" || { bad "firewall state changed"; diff <(echo "$before") <(echo "$after") | head -n 20 | sed 's/^/        /'; }
  for ch in INPUT FORWARD OUTPUT; do
    iptables -S "$ch" | grep -qx -- "-P $ch ACCEPT" && ok "iptables policy $ch still ACCEPT" || bad "iptables policy $ch changed"
  done
  rules=$(iptables -S | grep -c '^-A' || true)
  [ "$rules" = 0 ] && ok "no filter rules added" || bad "$rules filter rule(s) present"
fi
[ "$fail" -eq 0 ] && echo "META-FILE ($MODE): ALL PASSED" || { echo "META-FILE ($MODE): FAILURES"; exit 1; }
