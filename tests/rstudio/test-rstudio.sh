#!/usr/bin/env bash
# RStudio Server end to end (spec §13.3). Run INSIDE a container AS THE AGENT (uid 1000), after the
# firewall, with the owner's switch (/etc/firewall/rstudio: RSTUDIO=1) and password file
# (/run/secrets/rstudio-password) mounted as agent-up mounts them, and the fixture project in /workspace:
#   /workspace/<one>.Rproj + /workspace/.Rprofile from tests/rstudio/fixture-Rprofile (it writes
#   /tmp/rprofile-marker when an R session sources it).
# Starts rserver with agent-rstudio unless it already runs (the entrypoint path), signs in over HTTP like
# a browser (CSRF cookie + RSA-encrypted credentials), lets RStudio launch an R session, and checks what
# that session sees. Env: EXPECT_GH_TOKEN  value the container got for GH_TOKEN (checked in R's env)
#                         ANNOTATE=1       also print failures and metrics as GitHub annotations
set -uo pipefail
fail=0
ok(){ echo "OK:   $*"; }
bad(){ echo "FAIL: $*"; fail=1; [ "${ANNOTATE:-0}" != 1 ] || echo "::error title=RStudio Server::$*"; }
metric(){ echo "METRIC: $*"; [ "${ANNOTATE:-0}" != 1 ] || echo "::notice title=RStudio Server metric::$*"; }
U=http://127.0.0.1:8787
UA='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36'
W=$(mktemp -d)
c(){ curl -q -s -A "$UA" --max-time "${CT:-20}" "$@"; }
code(){ c -o /dev/null -w '%{http_code} %{redirect_url}' "$@"; }
PW=$(cat /run/secrets/rstudio-password 2>/dev/null) || PW=""

[ "$(id -un)" = agent ] && ok "running as agent" || bad "must run as agent, not $(id -un)"
[ -n "$PW" ] && ok "password file readable by the agent" || bad "/run/secrets/rstudio-password not readable"

# --- start (or find) the server; time it
if [ "$(code "$U/" | cut -d' ' -f1)" = 000 ]; then
  t0=$(date +%s.%N); out=$(agent-rstudio start); echo "$out"
  t1=$(date +%s.%N)
  grep -q 'server up' <<<"$out" && ok "agent-rstudio start: server up" || bad "agent-rstudio start: $out"
  metric "rserver startup (agent-rstudio start until port 8787 answers): $(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}') s"
else
  ok "rserver already running (started by the entrypoint)"
fi
grep -q 'already running' <<<"$(agent-rstudio start)" && ok "agent-rstudio start is idempotent" || bad "agent-rstudio start not idempotent"
rs_pid=$(pgrep -x rserver | head -n 1)
[ -n "$rs_pid" ] && [ "$(ps -o user= -p "$rs_pid")" = agent ] && ok "rserver runs as agent (pid $rs_pid), not root" \
  || bad "rserver not running as agent: $(ps -o user=,pid=,cmd= -C rserver)"
[ -z "$(pgrep -u 0 -f rstudio-server)" ] && ok "no root RStudio process" || bad "a root RStudio process: $(pgrep -u 0 -af rstudio-server)"
[ -s /var/lib/rstudio-agent/secure-cookie-key ] && ok "per-container cookie key minted at start (/var/lib/rstudio-agent)" \
  || bad "no /var/lib/rstudio-agent/secure-cookie-key"
sleep 2
metric "rserver idle RSS: $(ps -o rss= -p "$rs_pid" | awk '{printf "%.0f MB", $1/1024}')"

# --- unauthenticated: only the sign-in page
r=$(code "$U/"); [[ $r == 302\ *auth-sign-in* ]] && ok "/ redirects to sign-in when not signed in ($r)" || bad "/ without sign-in: $r"
c -c "$W/jar" -o "$W/signin.html" "$U/auth-sign-in"
grep -qi 'sign in' "$W/signin.html" && ok "sign-in page served" || bad "no sign-in page"
csrf=$(awk '$6=="rs-csrf-token"{print $7}' "$W/jar")
[ -n "$csrf" ] && ok "CSRF cookie set" || bad "no rs-csrf-token cookie"

# RSA public key (hex exponent:modulus) -> PKCS#1 v1.5 encryption of "user\npassword", base64: what the page's JS does.
enc(){ # $1 user, $2 password -> v
  local key e m
  key=$(c "$U/auth-public-key"); e=${key%%:*}; m=${key#*:}
  printf 'asn1=SEQUENCE:k\n[k]\nn=INTEGER:0x%s\ne=INTEGER:0x%s\n' "$m" "$e" > "$W/k.cnf"
  openssl asn1parse -genconf "$W/k.cnf" -out "$W/k.der" -noout >/dev/null 2>&1 \
    && openssl rsa -RSAPublicKey_in -inform DER -in "$W/k.der" -pubout -out "$W/k.pem" >/dev/null 2>&1 \
    && printf '%s\n%s' "$1" "$2" | openssl pkeyutl -encrypt -pubin -inkey "$W/k.pem" -pkeyopt rsa_padding_mode:pkcs1 | base64 -w0
}
signin(){ # $1 user, $2 password -> "<http code> <redirect>"; cookies in $W/jar
  local v; v=$(enc "$1" "$2") || { echo "ENC-FAILED"; return; }
  CT=30 code -b "$W/jar" -c "$W/jar" --data-urlencode "rs-csrf-token=$csrf" --data-urlencode "v=$v" \
    --data-urlencode "persist=0" --data-urlencode "appUri=" "$U/auth-do-sign-in"
}
# Signed in = the jar's cookies get the IDE instead of a redirect to the sign-in page.
signed_in(){ [[ $(code -b "$W/jar" "$U/") == 200* ]]; }
r=$(signin agent wrong-password-0000); [[ $r == *auth-sign-in*error* ]] && ! signed_in && ok "wrong password refused ($r)" || bad "wrong password: $r"
sleep 6   # auth-sign-in-throttle-seconds
r=$(signin root "$PW"); [[ $r == *auth-sign-in*error* ]] && ! signed_in && ok "right password, wrong user (root) refused" || bad "user root: $r"
sleep 6
r=$(signin agent "$PW")
if [[ $r == 302\ * ]] && [[ $r != *auth-sign-in* ]] && signed_in; then ok "agent + the owner's password signs in ($r)"; else bad "sign-in failed: $r"; fi

# --- the IDE page, then client_init (what the page's JS sends first): rserver launches an R session
# through rsession-agent on client_init, not on the page load.
rm -f /tmp/rprofile-marker
r=$(code -b "$W/jar" "$U/"); [[ $r == 200* ]] && ok "signed in: / serves the IDE (HTTP 200)" || bad "signed in: / gives $r"
t0=$(date +%s.%N)
r=$(CT=90 code -b "$W/jar" -c "$W/jar" -H "X-RS-CSRF-Token: $csrf" -H 'Content-Type: application/json' \
  --data '{"method":"client_init","params":["/"],"clientId":"agent-containers-test","clientVersion":""}' "$U/rpc/client_init")
echo "        POST /rpc/client_init: $r"
for _ in $(seq 1 90); do [ -s /tmp/rprofile-marker ] && break; sleep 1; done
t1=$(date +%s.%N)
if [ -s /tmp/rprofile-marker ]; then
  ok "the R session sourced /workspace/.Rprofile"
  metric "first R session (client_init until .Rprofile ran): $(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}') s"
  sed 's/^/        /' /tmp/rprofile-marker
  m(){ sed -n "s/^$1 //p" /tmp/rprofile-marker; }
  [ "$(m wd)" = /workspace ] && ok "R starts in /workspace" || bad "R working dir: $(m wd)"
  [[ ":$(m libpaths):" == :/tmp/fixture-lib:* ]] && ok "the session's .libPaths() leads with the project's library (from .Rprofile)" || bad ".libPaths(): $(m libpaths)"
  [ "$(m rstudio)" = 1 ] && ok "R runs inside RStudio (RSTUDIO=1)" || bad "RSTUDIO=$(m rstudio)"
  [ "$(m op_token)" = FALSE ] && ok "OP_SERVICE_ACCOUNT_TOKEN NOT in R's environment" || bad "OP_SERVICE_ACCOUNT_TOKEN reached R"
  if [ -n "${EXPECT_GH_TOKEN:-}" ]; then
    [ "$(m gh_token)" = "$EXPECT_GH_TOKEN" ] && ok "GH_TOKEN (project.env) reaches R, as in the agent's shell" || bad "GH_TOKEN in R: '$(m gh_token)'"
  fi
  [ "$(m home)" = /home/agent ] && ok "HOME=/home/agent in R" || bad "HOME in R: $(m home)"
else
  bad "no R session sourced /workspace/.Rprofile within 90 s"
fi
rsess=$(pgrep -x rsession | head -n 1)
if [ -n "$rsess" ]; then
  [ "$(ps -o user= -p "$rsess")" = agent ] && ok "rsession runs as agent" || bad "rsession user: $(ps -o user= -p "$rsess")"
  # (rsession consumes RS_INITIAL_PROJECT with unsetenv, which /proc/<pid>/environ does not show.)
  tr '\0' '\n' < "/proc/$rsess/environ" | grep -qx "RS_INITIAL_PROJECT=$(ls /workspace/*.Rproj)" && ok "rsession-agent set RS_INITIAL_PROJECT to the one .Rproj" || bad "RS_INITIAL_PROJECT not set for the first session"
  for _ in $(seq 1 20); do [ -d /workspace/.Rproj.user ] && break; sleep 1; done
  [ -d /workspace/.Rproj.user ] && ok "the session opened the project (.Rproj.user created)" || bad "the session did not open /workspace's .Rproj"
  sleep 3
  metric "rsession RSS (one fresh R session): $(ps -o rss= -p "$rsess" | awk '{printf "%.0f MB", $1/1024}'); rserver RSS: $(ps -o rss= -p "$rs_pid" | awk '{printf "%.0f MB", $1/1024}')"
else
  bad "no rsession process"
fi
ls -d /var/lib/rstudio-agent/initial-project-done >/dev/null 2>&1 && ok "first-session marker set (later sessions follow RStudio's own project choice)" || bad "no initial-project marker"
L="$HOME/.local/share/rstudio/agent-rserver.log"
grep -q 'rsession-env\] WARN' "$L" 2>/dev/null && bad "rsession-agent warned: $(grep 'rsession-env' "$L" | tail -n 2)" || ok "rsession-agent read the container environment (no warning)"
if [ "$fail" -ne 0 ]; then
  echo "---- $L (tail)"; tail -n 30 "$L" 2>/dev/null | sed 's/^/        /'
  for f in "$HOME"/.local/share/rstudio/log/*.log; do echo "---- $f (tail)"; tail -n 15 "$f" | sed 's/^/        /'; done
fi
rm -rf "$W"
[ "$fail" -eq 0 ] && echo "RSTUDIO: ALL PASSED" || { echo "RSTUDIO: FAILURES"; exit 1; }
