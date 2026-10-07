#!/usr/bin/env bash
# Unit test for init-firewall.sh's IPv6 "unavailable" classifier, against fixture strings.
# Run INSIDE the image WITHOUT NET_ADMIN (e.g. plain `docker run --rm`): it SOURCES the shipped
# script, which must define its functions and then return before doing anything.
set -uo pipefail
fail=0
ok(){ echo "OK:   $*"; }; bad(){ echo "FAIL: $*"; fail=1; }
S=${FIREWALL_SCRIPT:-/usr/local/bin/init-firewall.sh}
# Refuse to source a script that would RUN when sourced.
grep -qxF '[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0' "$S" || { bad "$S has no source guard; refusing to source it"; echo "V6-CLASSIFIER: FAILURES"; exit 1; }
# shellcheck disable=SC1090
source "$S"
set +e   # the script's set -e must not abort the assertions
declare -F v6_unavailable >/dev/null || { bad "v6_unavailable is not defined"; exit 1; }
T=$(mktemp -d)
LO='00000000000000000000000000000001 01 80 10 80       lo'
ETH='fd00deadbeef00000000000000000002 1b 40 00 00     eth0'
printf '%s\n' "$LO" > "$T/lo-only"; printf '%s\n%s\n' "$LO" "$ETH" > "$T/with-eth"; : > "$T/empty"
NOTABLE=$'ip6tables v1.8.10 (legacy): can\'t initialize ip6tables table `filter\': Table does not exist (do you need to insmod?)\nPerhaps ip6tables or your kernel needs to be upgraded.'
PERM=$'ip6tables v1.8.10 (legacy): can\'t initialize ip6tables table `filter\': Permission denied (you must be root)\nPerhaps ip6tables or your kernel needs to be upgraded.'
PERM_NFT='ip6tables v1.8.10 (nf_tables): Could not fetch rule set generation id: Permission denied (you must be root)'
LOCK='Another app is currently holding the xtables lock. Perhaps you want to use the -w option?'
case_(){ # $1 want(unavailable|available) $2 label $3 err $4 if_inet6 path
  if v6_unavailable "$3" "$4"; then got=unavailable; else got=available; fi
  [ "$got" = "$1" ] && ok "$2 -> $got" || bad "$2 -> $got, want $1"
}
case_ unavailable "no /proc/net/if_inet6 at all"                    "$LOCK"     "$T/missing"
case_ unavailable "table missing + only lo"                         "$NOTABLE"  "$T/lo-only"
case_ unavailable "table missing + empty if_inet6"                  "$NOTABLE"  "$T/empty"
case_ available   "table missing + a non-lo IPv6 address"           "$NOTABLE"  "$T/with-eth"
case_ available   "'Perhaps ... upgraded' permission msg + eth addr" "$PERM"    "$T/with-eth"
case_ unavailable "'Perhaps ... upgraded' permission msg + only lo"  "$PERM"    "$T/lo-only"
case_ available   "nft permission denied + eth addr"                "$PERM_NFT" "$T/with-eth"
case_ available   "nft permission denied + only lo (unknown error)" "$PERM_NFT" "$T/lo-only"
case_ available   "xtables lock + only lo (unknown error)"          "$LOCK"     "$T/lo-only"
case_ available   "empty error + only lo"                           ""          "$T/lo-only"
rm -rf "$T"
[ "$fail" -eq 0 ] && echo "V6-CLASSIFIER: ALL PASSED" || { echo "V6-CLASSIFIER: FAILURES"; exit 1; }
