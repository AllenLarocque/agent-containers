#!/bin/bash
# Default-deny egress firewall. GitHub ranges from api.github.com/meta; every other allowed
# domain is authorised lazily by dnsmasq inserting each resolved IP into the ipset (CDN IPs rotate).
# Domains come from /etc/firewall/allowlist.d/*.txt (base baked in; the project file is mounted
# read-only from the OWNER's host, never from the agent-writable workspace).
#
# FAIL-CLOSED INVARIANT: from the first mutation onward, EVERY intermediate state is deny-by-default.
#   0. Everything read-only runs first: allowlist validation, the original resolver, the dnsmasq
#      uid, Docker's DNS NAT rules, the ip6tables probe. Any failure there exits with NOTHING changed.
#   1. Per family, OUTPUT then INPUT then FORWARD policies go to DROP BEFORE the flush. Flushing a
#      DROP chain only removes ACCEPTs, so there is never a moment with an ACCEPT policy. IPv6 goes
#      first, so a later IPv4 failure cannot leave IPv6 open.
#   2. While building, only what setup needs is allowed: loopback, ESTABLISHED/RELATED, DNS to the
#      upstream for the dnsmasq uid ONLY, and (temporarily) HTTPS to api.github.com's resolved IPs
#      for the meta fetch. The temporary rules are removed after the fetch, and by an EXIT trap on
#      any failure.
#   3. Therefore ANY failure under set -e leaves the container closed. The final rules only ADD the
#      ipset ACCEPT and the closing REJECT.
#
# CONFINEMENT (owner decision 2026-10-04):
#   - No port-based bypasses: TCP 22 is allowed only to allowlisted hosts (ipset rule, ports
#     22/80/443). SSH to your own servers needs an allowlist entry.
#   - DNS: only the dnsmasq uid may reach the upstream resolver (UDP/TCP 53, owner match). Docker's
#     embedded resolver 127.0.0.11 is rejected for every other uid. dnsmasq forwards ONLY allowlisted
#     names (one server=/<domain>/ line each, no default server), so other names get REFUSED: no DNS
#     tunnelling through arbitrary domains. Root does not get upstream DNS either: the one setup
#     lookup (api.github.com) runs under the dnsmasq uid via setpriv.
#   - No host-network ACCEPT. VS Code attaches via `docker exec`; nothing listens for the host.
#     If a published port is ever needed, add ONE rule: -A INPUT -s $HOST_IP -p tcp --dport <port> -j ACCEPT
#   - Re-runnable (the agent may `sudo` it): the ORIGINAL resolver is persisted in /run/firewall-upstream
#     on first run, because afterwards /etc/resolv.conf points at dnsmasq (127.0.0.1).

# IPv6 is "unavailable" only if the kernel genuinely has no usable IPv6 to leak.
# $1 = ip6tables error text; $2 = if_inet6 path (default /proc/net/if_inet6; a parameter for the unit test).
v6_unavailable(){
  local ifinet6=${2:-/proc/net/if_inet6}
  [ ! -e "$ifinet6" ] && return 0
  # ip6tables table missing (or its "Perhaps ... upgraded" variants, which also cover permission
  # errors): acceptable ONLY if there is no non-loopback IPv6 address either.
  grep -qE "can't initialize ip6tables table|Table does not exist|Perhaps ip6tables or your kernel needs to be upgraded" <<<"$1" || return 1
  ! awk '$6!="lo"{f=1} END{exit !f}' "$ifinet6"
}
# Sourced (unit test): stop after the function definitions, before touching anything.
[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

set -euo pipefail
# Pin root's environment (sudo resets most of it; this does not depend on that): only system
# binaries, root's own HOME, no curl/dig rc files (curl -q, dig -r below).
export PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root
unset CURL_HOME
IFS=$'\n\t'
ALLOWLIST_DIR=/etc/firewall/allowlist.d
UPSTREAM_FILE=/run/firewall-upstream
DNSMASQ_CONF=/etc/dnsmasq.d/allowlist.conf

# ===================== 0. READ-ONLY PHASE (nothing below changes any state) =====================

# Parse every file line by line (never `cat` them together: a file without a trailing newline
# would glue its last line to the next file's first). Validate EVERY token here, before any
# change, so a bad entry aborts with the existing rules untouched (never fail open).
shopt -s nullglob
ALLOWLIST_FILES=("$ALLOWLIST_DIR"/*.txt)
shopt -u nullglob
DOMAIN_RE='^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'
RAW_DOMAINS=()
for f in "${ALLOWLIST_FILES[@]}"; do
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n+1))
    line=${line%$'\r'}; line=${line%%#*}     # a CR only as the line ending (CRLF); mid-line it is invalid
    [[ $line =~ ^[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]] || continue   # blank
    tok=${BASH_REMATCH[1]}
    if [[ ! $tok =~ $DOMAIN_RE ]]; then
      echo "ERROR: invalid allowlist entry in $f line $n: '$tok' (want a bare domain, e.g. example.org)"; exit 1
    fi
    RAW_DOMAINS+=("$tok")
  done < "$f"
done
if [ "${#RAW_DOMAINS[@]}" -eq 0 ]; then
  echo "ERROR: no domains found in $ALLOWLIST_DIR/*.txt"; exit 1
fi
mapfile -t ALLOWED_DOMAINS < <(printf '%s\n' "${RAW_DOMAINS[@]}" | tr 'A-Z' 'a-z' | sort -u)
echo "Allowlist: ${#ALLOWED_DOMAINS[@]} domains from $(printf '%s ' "${ALLOWLIST_FILES[@]##*/}")"

# The ORIGINAL upstream resolver. First run: /etc/resolv.conf (in Docker: 127.0.0.11 on user-defined
# networks, the host's resolver on the default bridge). Re-run: resolv.conf already points at our own
# dnsmasq, so use the value persisted on the first run.
UPSTREAM_DNS=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf)
PERSIST_UPSTREAM=1
if [ "$UPSTREAM_DNS" = 127.0.0.1 ]; then
  UPSTREAM_DNS=$(cat "$UPSTREAM_FILE" 2>/dev/null || true)
  PERSIST_UPSTREAM=0
  [ -n "$UPSTREAM_DNS" ] || { echo "ERROR: resolv.conf points at 127.0.0.1 but $UPSTREAM_FILE is missing: original resolver unknown"; exit 1; }
fi
if [ -z "$UPSTREAM_DNS" ]; then
  echo "ERROR: Could not determine upstream nameserver from /etc/resolv.conf"; exit 1
fi
if [[ ! $UPSTREAM_DNS =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || [ "$UPSTREAM_DNS" = 127.0.0.1 ]; then
  echo "ERROR: upstream nameserver '$UPSTREAM_DNS' is not a usable IPv4 address (IPv6 egress is denied)"; exit 1
fi
echo "Upstream DNS detected as: $UPSTREAM_DNS"

# The ONLY uid allowed to talk to the upstream resolver.
DNSMASQ_UID=$(id -u dnsmasq 2>/dev/null) && DNSMASQ_GID=$(id -g dnsmasq) \
  || { echo "ERROR: no 'dnsmasq' user in the image (DNS cannot be owner-restricted)"; exit 1; }
[ "$DNSMASQ_UID" -ne 0 ] || { echo "ERROR: dnsmasq user must not be uid 0"; exit 1; }
for t in conntrack setpriv dig ipset aggregate jq; do
  command -v "$t" >/dev/null || { echo "ERROR: $t not installed"; exit 1; }
done

# Docker's embedded-DNS NAT rules (127.0.0.11 -> its real port), to restore after the flush.
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# IPv6 probe (read-only).
command -v ip6tables >/dev/null || { echo "ERROR: ip6tables not installed - cannot enforce IPv6 default-deny"; exit 1; }
IPV6_STATE=filtered
if ! v6_err=$(ip6tables -S 2>&1 >/dev/null); then
  if v6_unavailable "$v6_err"; then
    IPV6_STATE=unavailable
  else
    echo "ERROR: ip6tables failed, refusing to continue with IPv6 unfiltered: $v6_err"; exit 1
  fi
fi

# ===================== 1. MUTATIONS (every intermediate state is deny-by-default) =====================

# Any failure from here on: drop the setup-only ACCEPTs too (the policies are already DROP).
SETUP_GH_IPS=()
cleanup_on_failure(){
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    for ip in "${SETUP_GH_IPS[@]}"; do iptables -D OUTPUT -p tcp -d "$ip" --dport 443 -j ACCEPT 2>/dev/null || true; done
    echo "ERROR: firewall setup failed (rc=$rc); the container is left CLOSED (policies DROP)"
  fi
}
trap cleanup_on_failure EXIT

# Default-DENY policies for BOTH families before EITHER flush (OUTPUT first in each), so from the
# first mutation on neither family is ever open, even on the very first run.
if [ "$IPV6_STATE" = filtered ]; then
  ip6tables -P OUTPUT DROP
  ip6tables -P INPUT DROP
  ip6tables -P FORWARD DROP
fi
iptables -P OUTPUT DROP
iptables -P INPUT DROP
iptables -P FORWARD DROP

# IPv6: no allowlist (tools fall back to IPv4).
if [ "$IPV6_STATE" = filtered ]; then
  ip6tables -F
  ip6tables -X
  ip6tables -A INPUT -i lo -j ACCEPT
  ip6tables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
  ip6tables -A OUTPUT -o lo -j ACCEPT
  ip6tables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
  echo "IPv6 default-deny applied (loopback + established only)"
else
  echo "IPv6 unavailable in kernel — nothing to filter"
fi

iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
# Kill connections opened before the firewall (or under a previous ruleset): without this their
# conntrack entries would keep matching the ESTABLISHED rule below.
conntrack -F >/dev/null
# Re-run: stop the previous dnsmasq (old config) and wait until 127.0.0.1:53 is free.
pkill -x dnsmasq 2>/dev/null || true
for _ in $(seq 1 50); do pgrep -x dnsmasq >/dev/null || break; sleep 0.1; done
ipset destroy allowed-domains 2>/dev/null || true

[ "$PERSIST_UPSTREAM" = 1 ] && { umask 022; echo "$UPSTREAM_DNS" > "$UPSTREAM_FILE"; }

# Restore ONLY Docker's internal DNS NAT (it rewrites 127.0.0.11:53 to the resolver's real port).
if [ -n "$DOCKER_DNS_RULES" ]; then
  echo "Restoring Docker DNS rules..."
  iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
  iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
  echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
  echo "No Docker DNS rules to restore"
fi

# Docker's embedded resolver is reachable over loopback: reject it for every uid but dnsmasq's,
# BEFORE the loopback ACCEPT. (After the nat DNAT the port is no longer 53, but the destination
# address is still 127.0.0.11, so this matches both UDP and TCP.)
iptables -A OUTPUT -d 127.0.0.11 -m owner ! --uid-owner "$DNSMASQ_UID" -j REJECT
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
# Upstream DNS: dnsmasq's uid only, only to the original resolver. Replies: ESTABLISHED above.
# (When the upstream is 127.0.0.11 these never match: the DNAT'd query leaves via lo, which the
# 127.0.0.11 REJECT above already restricts to the dnsmasq uid.)
iptables -A OUTPUT -d "$UPSTREAM_DNS" -p udp --dport 53 -m owner --uid-owner "$DNSMASQ_UID" -j ACCEPT
iptables -A OUTPUT -d "$UPSTREAM_DNS" -p tcp --dport 53 -m owner --uid-owner "$DNSMASQ_UID" -j ACCEPT

# Temporary: HTTPS to api.github.com's current IPv4s so the meta fetch can run under default-deny.
# Resolved with the dnsmasq uid (the only uid with upstream DNS), straight at the original resolver.
mapfile -t SETUP_GH_IPS < <(setpriv --reuid="$DNSMASQ_UID" --regid="$DNSMASQ_GID" --clear-groups \
  dig -r +short +time=3 +tries=2 A api.github.com @"$UPSTREAM_DNS" 2>/dev/null | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | sort -u || true)
if [ "${#SETUP_GH_IPS[@]}" -eq 0 ]; then
  echo "ERROR: could not resolve api.github.com (firewall left closed)"; exit 1
fi
for ip in "${SETUP_GH_IPS[@]}"; do
  iptables -A OUTPUT -p tcp -d "$ip" --dport 443 -j ACCEPT
done
echo "Temporary setup rules: HTTPS to api.github.com at $(printf '%s ' "${SETUP_GH_IPS[@]}")"

ipset create allowed-domains hash:net

echo "Fetching GitHub IP ranges..."
# --resolve pins curl to exactly the IPs allowed above.
GH_RESOLVE="api.github.com:443:$(IFS=,; echo "${SETUP_GH_IPS[*]}")"
gh_ranges=$(curl -q -sS --connect-timeout 10 --max-time 30 --resolve "$GH_RESOLVE" https://api.github.com/meta)
if [ -z "$gh_ranges" ]; then
  echo "ERROR: Failed to fetch GitHub IP ranges"; exit 1
fi
if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
  echo "ERROR: GitHub API response missing required fields"; exit 1
fi

echo "Processing GitHub IPs..."
added=0
while read -r cidr; do
  if [[ ! "$cidr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]]; then
    echo "ERROR: Invalid CIDR range from GitHub meta: $cidr"; exit 1
  fi
  for o in 1 2 3 4; do
    [ "${BASH_REMATCH[$o]}" -le 255 ] || { echo "ERROR: Invalid octet in GitHub meta range: $cidr"; exit 1; }
  done
  # A short prefix would open a huge slice of the internet: never accept anything broader than /16.
  if [ "${BASH_REMATCH[5]}" -lt 16 ] || [ "${BASH_REMATCH[5]}" -gt 32 ]; then
    echo "ERROR: GitHub meta range $cidr has prefix /${BASH_REMATCH[5]} (allowed: /16 to /32)"; exit 1
  fi
  echo "Adding GitHub range $cidr"
  ipset add allowed-domains "$cidr"
  added=$((added+1))
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)
# A jq/aggregate failure inside the process substitution would otherwise pass silently.
if [ "$added" -eq 0 ]; then
  echo "ERROR: no GitHub IP ranges were added from api.github.com/meta"; exit 1
fi
echo "Added $added GitHub range(s)"

# Meta ranges are in the ipset now: drop the temporary setup-only rules.
for ip in "${SETUP_GH_IPS[@]}"; do
  iptables -D OUTPUT -p tcp -d "$ip" --dport 443 -j ACCEPT
done
SETUP_GH_IPS=()

# dnsmasq: resolves ONLY allowlisted names (and their subdomains) and inserts exactly the IPs each
# lookup returns into the ipset, so CDN IP rotation can never desync the allowlist.
# No default server= line: any other name is REFUSED (no DNS tunnelling through arbitrary domains).
mkdir -p /etc/dnsmasq.d
{
  echo "no-resolv"
  echo "user=dnsmasq"
  echo "listen-address=127.0.0.1"
  echo "bind-interfaces"
  # One line per domain: a single joined ipset= line overflows dnsmasq's config line limit.
  for d in "${ALLOWED_DOMAINS[@]}"; do echo "server=/$d/$UPSTREAM_DNS"; done
  for d in "${ALLOWED_DOMAINS[@]}"; do echo "ipset=/$d/allowed-domains"; done
} > "$DNSMASQ_CONF.tmp"
chmod 0644 "$DNSMASQ_CONF.tmp"
mv "$DNSMASQ_CONF.tmp" "$DNSMASQ_CONF"
dnsmasq --conf-file="$DNSMASQ_CONF"

# Route all in-container DNS through dnsmasq.
echo "nameserver 127.0.0.1" > /etc/resolv.conf

# Prime the ipset for the allowlisted domains (also a dnsmasq sanity check).
for domain in "${ALLOWED_DOMAINS[@]}"; do
  dig -r +short "$domain" @127.0.0.1 >/dev/null 2>&1 || true
done

# Only allowlisted destinations, only on SSH/HTTP/HTTPS.
iptables -A OUTPUT -p tcp -m set --match-set allowed-domains dst -m multiport --dports 22,80,443 -j ACCEPT
# Explicitly REJECT all other outbound traffic for immediate feedback.
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo "Firewall configuration complete"
echo "Verifying firewall rules..."
for ch in INPUT FORWARD OUTPUT; do
  if ! iptables -S "$ch" | grep -qx -- "-P $ch DROP"; then
    echo "ERROR: Firewall verification failed - iptables $ch policy is not DROP"; exit 1
  fi
done
if iptables -S OUTPUT | grep -q -- '--dport 443 -j ACCEPT'; then
  echo "ERROR: Firewall verification failed - a temporary setup rule (--dport 443 -j ACCEPT) is still present"; exit 1
fi
if curl -q --connect-timeout 5 https://1.1.1.1/ >/dev/null 2>&1; then
  echo "ERROR: Firewall verification failed - was able to reach https://1.1.1.1 (literal IP)"; exit 1
fi
if dig -r +short +time=3 +tries=1 example.com @127.0.0.1 2>/dev/null | grep -qE '^[0-9.]+$'; then
  echo "ERROR: Firewall verification failed - dnsmasq resolved non-allowlisted example.com"; exit 1
fi
echo "Firewall verification passed - literal IP blocked, non-allowlisted names not resolved"

if [ "$IPV6_STATE" = filtered ]; then
  for ch in INPUT FORWARD OUTPUT; do
    if ! ip6tables -S "$ch" | grep -qx -- "-P $ch DROP"; then
      echo "ERROR: Firewall verification failed - ip6tables $ch policy is not DROP"; exit 1
    fi
  done
  if curl -q -6 --connect-timeout 5 https://www.google.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://www.google.com over IPv6"; exit 1
  fi
  echo "Firewall verification passed - IPv6 egress denied (ip6tables policies DROP)"
else
  echo "IPv6 verification skipped - IPv6 unavailable in kernel"
fi

if ! curl -q --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
  echo "ERROR: Firewall verification failed - unable to reach https://api.github.com"; exit 1
fi
echo "Firewall verification passed - able to reach https://api.github.com as expected"

# Soft check: a transient CRAN outage should not brick container startup, but a broken
# dynamic allowlist should be visible in the log.
if curl -q --connect-timeout 8 -sSf https://cloud.r-project.org/src/contrib/PACKAGES.gz >/dev/null 2>&1; then
  echo "Firewall verification passed - CRAN reachable via dnsmasq dynamic allowlist"
else
  echo "WARNING: could not reach CRAN (cloud.r-project.org) right now - if this persists, check dnsmasq/resolv.conf"
fi
