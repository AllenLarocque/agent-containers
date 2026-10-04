#!/usr/bin/env bash
# Run INSIDE a started container AS ROOT, BEFORE any firewall init. An invalid allowlist entry
# must make init-firewall.sh fail closed-early: non-zero exit, a validation error naming the
# file + line, and NO change to iptables (it must not flush rules and then die before DROP).
set -uo pipefail
fail=0
D=/etc/firewall/allowlist.d
snap(){ { iptables -S; iptables -t nat -S; ipset list -n 2>/dev/null; } 2>&1; }
try(){ # $1 = label, $2 = file content (printf format)
  printf "$2" > "$D/60-bad.txt"
  local before after out rc
  before=$(snap)
  out=$(/usr/local/bin/init-firewall.sh 2>&1); rc=$?
  after=$(snap)
  rm -f "$D/60-bad.txt"
  [ "$rc" -ne 0 ] && echo "OK:   [$1] exit non-zero ($rc)" || { echo "FAIL: [$1] exited 0"; fail=1; }
  echo "$out" | grep -q "invalid allowlist entry.*60-bad.txt" && echo "OK:   [$1] validation error names file" \
    || { echo "FAIL: [$1] no validation error in output:"; echo "$out" | tail -5; fail=1; }
  [ "$before" = "$after" ] && echo "OK:   [$1] iptables/ipset untouched" || { echo "FAIL: [$1] iptables state changed"; fail=1; }
}
try "url"            'https://bad.example/x\n'
try "internal space" 'foo bar\n'
try "wildcard"       '*.bad.example\n'
try "port"           'bad.example:443\n'
[ "$fail" -eq 0 ] && echo "INVALID-TOKEN: ALL PASSED" || { echo "INVALID-TOKEN: FAILURES"; exit 1; }
