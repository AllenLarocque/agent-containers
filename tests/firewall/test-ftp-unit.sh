#!/usr/bin/env bash
# Unit test for init-firewall.sh's domain matching used by the FTP hosts (spec §13.4): covered_by
# decides which sets a name's ONE dnsmasq ipset= line names (a name covers its subdomains; dnsmasq's
# longest ipset= match wins), one_of whether an FTP host already has the allowlist's server= line.
# Run INSIDE the image WITHOUT NET_ADMIN (e.g. plain `docker run --rm`), or anywhere with
# FIREWALL_SCRIPT=images/base/init-firewall.sh: it SOURCES the script, which must define its
# functions and then return before doing anything.
set -uo pipefail
fail=0
ok(){ echo "OK:   $*"; }; bad(){ echo "FAIL: $*"; fail=1; }
S=${FIREWALL_SCRIPT:-/usr/local/bin/init-firewall.sh}
# Refuse to source a script that would RUN when sourced.
grep -qxF '[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0' "$S" || { bad "$S has no source guard; refusing to source it"; echo "FTP-UNIT: FAILURES"; exit 1; }
# shellcheck disable=SC1090
source "$S"
set +e   # the script's set -e must not abort the assertions
for f in covered_by one_of; do
  declare -F "$f" >/dev/null || { bad "$f is not defined"; echo "FTP-UNIT: FAILURES"; exit 1; }
done
cov(){ # $1 want(yes|no) $2 name, rest = list
  local want=$1 d=$2 got; shift 2
  if covered_by "$d" "$@"; then got=yes; else got=no; fi
  [ "$got" = "$want" ] && ok "covered_by $d [$*] -> $got" || bad "covered_by $d [$*] -> $got, want $want"
}
cov yes webin2.ebi.ac.uk     webin2.ebi.ac.uk
cov yes webin2.ebi.ac.uk     ebi.ac.uk
cov yes a.b.ebi.ac.uk        ebi.ac.uk
cov no  ebi.ac.uk            webin2.ebi.ac.uk          # a parent is not covered by its subdomain
cov no  xebi.ac.uk           ebi.ac.uk                 # whole labels only
cov no  ebi.ac.uk.evil.org   ebi.ac.uk                 # suffix, not prefix
cov no  webin2xebi.ac.uk     ebi.ac.uk
cov no  webin2.ebi.ac.uk     ""                        # an empty entry covers nothing
cov yes ftp.ebi.ac.uk        github.com ebi.ac.uk      # any entry of the list
cov no  ftp.ebi.ac.uk        github.com ncbi.nlm.nih.gov
cov no  ftp.ebi.ac.uk                                  # empty list
cov yes argotunnel.com       argotunnel.com
cov yes region1.v2.argotunnel.com argotunnel.com
cov no  argotunnel.com       region1.v2.argotunnel.com
cov no  "ebi.ac.uk"          "*.ac.uk"                 # list entries are literal, never globs
one(){ # $1 want(yes|no) $2 name, rest = list
  local want=$1 d=$2 got; shift 2
  if one_of "$d" "$@"; then got=yes; else got=no; fi
  [ "$got" = "$want" ] && ok "one_of $d [$*] -> $got" || bad "one_of $d [$*] -> $got, want $want"
}
one yes ftp.ebi.ac.uk  github.com ftp.ebi.ac.uk
one no  ftp.ebi.ac.uk  ebi.ac.uk                       # exact only (subdomains: covered_by)
one no  ftp.ebi.ac.uk
one no  ftp.ebi.ac.uk  "ftp.ebi.ac.*"
[ "$fail" -eq 0 ] && echo "FTP-UNIT: ALL PASSED" || { echo "FTP-UNIT: FAILURES"; exit 1; }
