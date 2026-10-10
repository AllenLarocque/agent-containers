#!/usr/bin/env bash
# Run INSIDE a started container AS ROOT, BEFORE any firewall init. An invalid allowlist entry
# must make init-firewall.sh fail closed-early: non-zero exit, a validation error naming the
# file + line, and NO change to iptables/ip6tables (it must not flush rules and then die before DROP).
set -uo pipefail
fail=0
D=/etc/firewall/allowlist.d
snap(){ { iptables -S; iptables -t nat -S; ip6tables -S; ipset list -n 2>/dev/null; } 2>&1; }
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
  [ "$before" = "$after" ] && echo "OK:   [$1] iptables/ip6tables/ipset untouched" || { echo "FAIL: [$1] iptables state changed"; fail=1; }
}
try "url"            'https://bad.example/x\n'
try "internal space" 'foo bar\n'
try "wildcard"       '*.bad.example\n'
try "port"           'bad.example:443\n'
# A CR is only a line-ending artefact at the END of a line; mid-line it must not be silently deleted
# ("foo\\rbar.example" would otherwise become the different, valid domain foobar.example).
try "mid-line CR"    'foo\rbar.example\n'
# The T3 Connect switch (spec §13.1): anything but exactly T3_CONNECT=0/1 fails closed-early too.
try_switch(){ # $1 = label, $2 = switch content (printf format)
  printf "$2" > /etc/firewall/t3-connect
  local before after out rc
  before=$(snap)
  out=$(/usr/local/bin/init-firewall.sh 2>&1); rc=$?
  after=$(snap)
  rm -f /etc/firewall/t3-connect
  [ "$rc" -ne 0 ] && echo "OK:   [switch $1] exit non-zero ($rc)" || { echo "FAIL: [switch $1] exited 0"; fail=1; }
  echo "$out" | grep -q "t3-connect must hold exactly" && echo "OK:   [switch $1] validation error names the switch" \
    || { echo "FAIL: [switch $1] no validation error in output:"; echo "$out" | tail -5; fail=1; }
  [ "$before" = "$after" ] && echo "OK:   [switch $1] iptables/ip6tables/ipset untouched" || { echo "FAIL: [switch $1] iptables state changed"; fail=1; }
}
try_switch "yes"        'T3_CONNECT=yes\n'
try_switch "bare 1"     '1\n'
try_switch "two lines"  'T3_CONNECT=1\nT3_CONNECT=1\n'
try_switch "empty"      ''
[ "$fail" -eq 0 ] && echo "INVALID-TOKEN: ALL PASSED" || { echo "INVALID-TOKEN: FAILURES"; exit 1; }
