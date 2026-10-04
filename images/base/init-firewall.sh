#!/bin/bash
# Default-deny egress firewall. GitHub ranges from api.github.com/meta; every other allowed
# domain is authorised lazily by dnsmasq inserting each resolved IP into the ipset (CDN IPs rotate).
# Domains come from /etc/firewall/allowlist.d/*.txt (base baked in; project mounted).
set -euo pipefail
IFS=$'\n\t'
ALLOWLIST_DIR=/etc/firewall/allowlist.d

# Parse every file line by line (never `cat` them together: a file without a trailing newline
# would glue its last line to the next file's first). Validate EVERY token here, before any
# iptables change, so a bad entry aborts with the existing rules untouched (never fail open).
shopt -s nullglob
ALLOWLIST_FILES=("$ALLOWLIST_DIR"/*.txt)
shopt -u nullglob
DOMAIN_RE='^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'
RAW_DOMAINS=()
for f in "${ALLOWLIST_FILES[@]}"; do
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n+1))
    line=${line%%#*}; line=${line//$'\r'/}
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
mapfile -t ALLOWED_DOMAINS < <(printf '%s\n' "${RAW_DOMAINS[@]}" | sort -u)
echo "Allowlist: ${#ALLOWED_DOMAINS[@]} domains from $(printf '%s ' "${ALLOWLIST_FILES[@]##*/}")"

# IPv6: default-DENY, no allowlist (tools fall back to IPv4). Applied BEFORE any IPv4 mutation, and
# after token validation, so the two failure modes are both safe: a bad token aborts above with
# NOTHING touched; an ip6tables failure here aborts (non-zero) with IPv4 still in its original
# state; and once this block has run, a later IPv4 failure cannot leave IPv6 open. Policies go to
# DROP before the flush so there is no window where IPv6 is unfiltered.
IPV6_STATE=filtered
v6_unavailable(){ # true only if the kernel genuinely has no usable IPv6 to leak
  [ ! -e /proc/net/if_inet6 ] && return 0
  # ip6tables table missing: acceptable only if there is no non-loopback IPv6 address either
  grep -qE "can't initialize ip6tables table|Table does not exist|Perhaps ip6tables or your kernel needs to be upgraded" <<<"$1" || return 1
  ! awk '$6!="lo"{f=1} END{exit !f}' /proc/net/if_inet6
}
command -v ip6tables >/dev/null || { echo "ERROR: ip6tables not installed - cannot enforce IPv6 default-deny"; exit 1; }
if v6_err=$(ip6tables -S 2>&1 >/dev/null); then
  ip6tables -P INPUT DROP
  ip6tables -P FORWARD DROP
  ip6tables -P OUTPUT DROP
  ip6tables -F
  ip6tables -X
  ip6tables -A INPUT -i lo -j ACCEPT
  ip6tables -A OUTPUT -o lo -j ACCEPT
  ip6tables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
  ip6tables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
  echo "IPv6 default-deny applied (loopback + established only)"
elif v6_unavailable "$v6_err"; then
  IPV6_STATE=unavailable
  echo "IPv6 unavailable in kernel — nothing to filter"
else
  echo "ERROR: ip6tables failed, refusing to continue with IPv6 unfiltered: $v6_err"; exit 1
fi

# Capture the current upstream nameserver BEFORE we rewrite resolv.conf.
# In Docker this is normally the embedded DNS at 127.0.0.11.
UPSTREAM_DNS=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf)
if [ -z "$UPSTREAM_DNS" ]; then
    echo "ERROR: Could not determine upstream nameserver from /etc/resolv.conf"
    exit 1
fi
if [[ ! $UPSTREAM_DNS =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    echo "ERROR: upstream nameserver '$UPSTREAM_DNS' is not an IPv4 address (IPv6 egress is denied)"
    exit 1
fi
echo "Upstream DNS detected as: $UPSTREAM_DNS"

# 1. Extract Docker DNS info BEFORE any flushing
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Flush existing rules and delete existing ipsets
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# 2. Selectively restore ONLY internal Docker DNS resolution
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

# First allow DNS and localhost before any restrictions
# Allow outbound DNS
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
# Allow inbound DNS responses
iptables -A INPUT -p udp --sport 53 -j ACCEPT
# DNS over TCP (dnsmasq retries over TCP on truncated answers): ONLY to the upstream resolver.
# Replies are covered by the ESTABLISHED,RELATED INPUT rule added below.
iptables -A OUTPUT -p tcp -d "$UPSTREAM_DNS" --dport 53 -j ACCEPT
# Allow outbound SSH
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
# Allow inbound SSH responses
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
# Allow localhost
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Create ipset with CIDR support
ipset create allowed-domains hash:net

# Fetch GitHub meta information and aggregate + add their IP ranges
echo "Fetching GitHub IP ranges..."
gh_ranges=$(curl -s https://api.github.com/meta)
if [ -z "$gh_ranges" ]; then
    echo "ERROR: Failed to fetch GitHub IP ranges"
    exit 1
fi

if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
    echo "ERROR: GitHub API response missing required fields"
    exit 1
fi

echo "Processing GitHub IPs..."
while read -r cidr; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
       echo "ERROR: Invalid CIDR range from GitHub meta: $cidr"
        exit 1
    fi
    echo "Adding GitHub range $cidr"
    ipset add allowed-domains "$cidr"
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)

# Resolve all non-GitHub allowed domains dynamically via a local dnsmasq
# resolver. dnsmasq inserts exactly the IPs each lookup returns into the
# allowed-domains ipset, so CDN IP rotation can never desync the allowlist.
# (cloud.r-project.org is a CNAME onto AWS CloudFront, whose edge IPs rotate;
# pinning a single resolved IP at container start was why CRAN went unreachable
# after a while. Now every DNS lookup lazily authorizes its own resolved IP
# just-in-time, immediately before the connection.)



# Build the dnsmasq ipset directive: ipset=/dom1/dom2/.../allowed-domains
IPSET_DIRECTIVE="ipset=/$(IFS=/; echo "${ALLOWED_DOMAINS[*]}")/allowed-domains"

mkdir -p /etc/dnsmasq.d
cat > /etc/dnsmasq.d/allowlist.conf <<EOF
no-resolv
server=${UPSTREAM_DNS}
listen-address=127.0.0.1
bind-interfaces
${IPSET_DIRECTIVE}
EOF

# (Re)start dnsmasq so it picks up the config.
pkill dnsmasq 2>/dev/null || true
dnsmasq --conf-file=/etc/dnsmasq.d/allowlist.conf

# Route all in-container DNS through dnsmasq so every lookup lazily authorizes
# its own resolved IP into the ipset.
echo "nameserver 127.0.0.1" > /etc/resolv.conf

# Prime the ipset for the base infra domains (also a dnsmasq sanity check).
for domain in "${ALLOWED_DOMAINS[@]}"; do
    dig +short "$domain" @127.0.0.1 >/dev/null 2>&1 || true
done

# Get host IP from default route
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi

HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "Host network detected as: $HOST_NETWORK"

# Set up remaining iptables rules
iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# Set default policies to DROP first
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# First allow established connections for already approved traffic
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Then allow only specific outbound traffic to allowed domains
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# Explicitly REJECT all other outbound traffic for immediate feedback
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo "Firewall configuration complete"
echo "Verifying firewall rules..."
if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://example.com"
    exit 1
else
    echo "Firewall verification passed - unable to reach https://example.com as expected"
fi

if [ "$IPV6_STATE" = filtered ]; then
    if ! ip6tables -S | grep -qx -- '-P OUTPUT DROP'; then
        echo "ERROR: Firewall verification failed - ip6tables OUTPUT policy is not DROP"
        exit 1
    fi
    if curl -6 --connect-timeout 5 https://www.google.com >/dev/null 2>&1; then
        echo "ERROR: Firewall verification failed - was able to reach https://www.google.com over IPv6"
        exit 1
    fi
    echo "Firewall verification passed - IPv6 egress denied (ip6tables OUTPUT policy DROP)"
else
    echo "IPv6 verification skipped - IPv6 unavailable in kernel"
fi

# Verify GitHub API access
if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://api.github.com"
    exit 1
else
    echo "Firewall verification passed - able to reach https://api.github.com as expected"
fi

# Verify CRAN (AWS CloudFront) is reachable via the dnsmasq dynamic ipset.
# Soft check: a transient CRAN outage should not brick container startup, but a
# broken dynamic-allowlist should be visible in the log.
if curl --connect-timeout 8 -sSf https://cloud.r-project.org/src/contrib/PACKAGES.gz >/dev/null 2>&1; then
    echo "Firewall verification passed - CRAN reachable via dnsmasq dynamic allowlist"
else
    echo "WARNING: could not reach CRAN (cloud.r-project.org) right now - if this persists, check dnsmasq/resolv.conf"
fi
