#!/bin/bash
# Default-deny egress firewall. GitHub ranges from api.github.com/meta; every other allowed
# domain is authorised lazily by dnsmasq inserting each resolved IP into the ipset (CDN IPs rotate).
# Domains come from /etc/firewall/allowlist.d/*.txt (base baked in; the project file is mounted
# read-only from the OWNER's host, never from the agent-writable workspace).
#
# FAIL-CLOSED INVARIANT: from the first mutation onward, EVERY intermediate state is deny-by-default.
#   0. Everything read-only runs first: allowlist validation, the FTP host list (+ the helper and raw
#      table probes), the original resolver, the dnsmasq uid, Docker's DNS NAT rules, the ip6tables
#      probe. Any failure there exits with NOTHING changed.
#   1. Per family, OUTPUT then INPUT then FORWARD policies go to DROP BEFORE the flush. Flushing a
#      DROP chain only removes ACCEPTs, so there is never a moment with an ACCEPT policy. IPv6 goes
#      first, so a later IPv4 failure cannot leave IPv6 open.
#   2. While building, only what setup needs is allowed: loopback, ESTABLISHED/RELATED, DNS to the
#      upstream for the dnsmasq uid ONLY, and (temporarily) HTTPS to api.github.com's resolved IPs
#      for the meta fetch. The temporary rules are removed after the fetch, and by an EXIT trap on
#      any failure. When the host mounts /etc/firewall/github-meta.json (CI only), there is no fetch
#      and no temporary rule: the ranges come from that file, checked exactly like fetched ones.
#   3. Therefore ANY failure under set -e leaves the container closed. The final rules only ADD the
#      T3 INPUT accept (gateway only), the RStudio INPUT accept (gateway only, only when the owner
#      enabled it), the ipset ACCEPT, the T3 Connect tunnel ACCEPTs (only when the owner enabled it),
#      the FTP helper (raw table) + tcp 21 ACCEPT (only for the owner's FTP hosts) and the closing REJECT.
#
# CONFINEMENT (owner decision 2026-10-04):
#   - No port-based bypasses: TCP 22 is allowed only to allowlisted hosts (ipset rule, ports
#     22/80/443). SSH to your own servers needs an allowlist entry. The ONE exception is FTP below
#     (tcp 21, only to the owner's separate FTP host list, decision 2026-10-11).
#   - DNS: only the dnsmasq uid may reach the upstream resolver (UDP/TCP 53, owner match). Docker's
#     embedded resolver 127.0.0.11 is rejected for every other uid. dnsmasq forwards ONLY allowlisted
#     names (one server=/<domain>/ line each, no default server), so other names get REFUSED: no DNS
#     tunnelling through arbitrary domains. Root does not get upstream DNS either: the one setup
#     lookup (api.github.com) runs under the dnsmasq uid via setpriv.
#   - ONE inbound exception: the T3 Code server (tcp 3773), from the container's gateway only (the
#     Docker host; compose publishes it on the host's 127.0.0.1). VS Code attaches via `docker exec`.
#     A second one ONLY where the owner enabled RStudio Server (below): tcp 8787, same pattern.
#   - Re-runnable (the agent may `sudo` it): the ORIGINAL resolver is persisted in /run/firewall-upstream
#     on first run, because afterwards /etc/resolv.conf points at dnsmasq (127.0.0.1).
#
# T3 CONNECT (owner opt-in per project, decision 2026-10-09, spec §13.1): when /etc/firewall/t3-connect
# says T3_CONNECT=1, t3.codes joins the allowlist (relay + login, ports 22/80/443 like any entry) and
# argotunnel.com resolves too, but its addresses go into a SEPARATE ipset (t3-tunnel) that is open on
# port 7844 ONLY (cloudflared: QUIC/UDP, HTTP2/TCP fallback). 7844 is never open to any other host.
# T3_CONNECT=publish is the notifications-only variant: t3.codes joins the allowlist (the relay, for
# push notifications) but there is NO tunnel: no argotunnel.com, no t3-tunnel ipset, no 7844 rule.
# Absent file (or T3_CONNECT=0): the rules are exactly the ones without the feature.
#
# RESEARCH PROFILE (owner decision 2026-10-09, spec §2.1): when /etc/firewall/profile says
# PROFILE=research (agent-up mounts it read-only for the shared research container ONLY), egress is
# OPEN to PUBLIC IPv4 on any TCP/UDP port and dnsmasq forwards every name (no allowlist rule; the setup
# steps, GitHub meta fetch included, run exactly as for builders, and their ipsets go unused). Still DENIED: every private, shared, link-local, loopback (except lo itself),
# benchmarking, multicast and reserved range (RESEARCH_DENY below), the container's gateway (the host)
# and its own networks. Everything else is unchanged: the same DROP-first ordering, owner-only upstream
# DNS, the T3 INPUT rule from the gateway only, IPv6 default-deny, idempotent re-run.
# Absent file (or PROFILE=builder): the builder rules, byte-identical to before (CI snapshot).
# RSTUDIO SERVER (owner opt-in per project, decision 2026-10-09, spec §13.3): when /etc/firewall/rstudio
# says RSTUDIO=1, ONE more INPUT rule accepts tcp 8787 from the container's gateway only (the host;
# compose publishes it on the host's 127.0.0.1), exactly like the T3 rule. No egress change.
# Absent file (or RSTUDIO=0): the rules are exactly the ones without the feature.
# FTP (owner opt-in per project, decision 2026-10-11, spec §13.4): when /etc/firewall/ftp-hosts exists
# (agent-up writes it from FTP_HOSTS in project.conf: one bare domain per line, parsed like the
# allowlist), those names resolve through dnsmasq and their addresses go into a SEPARATE ipset
# (ftp-hosts) that is open on tcp 21 ONLY. Passive data connections are not opened by port: the
# kernel's FTP conntrack helper, attached explicitly in the raw table (our own AGENT_FTP chain; the
# kernel no longer assigns helpers automatically), reads the server's EPSV/PASV reply and expects the
# data connection, which then matches the ESTABLISHED,RELATED accept. No high-port range is opened.
# Needs nf_conntrack_ftp in the HOST kernel (a container cannot load modules). FTP is cleartext: the
# credentials and the data cross the network in the clear (ENA Webin's documented route), so keep the
# list narrow. A name covers its subdomains, as in the allowlist. Builders only: research rejects it.
# Absent file: the rules are exactly the ones without the feature (nothing in the raw table).

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
# Is domain $1 one of the domains in the remaining arguments, or a subdomain of one? dnsmasq's own
# rule (a server=/ipset= line covers the name and its subdomains; for ipset= the LONGEST match wins,
# so a name listed in both the allowlist and the FTP hosts, or under one and listed in the other, needs
# ONE ipset= line naming every set that covers it). Exact label match: "xebi.ac.uk" is not under "ebi.ac.uk".
covered_by(){
  local d=$1 n; shift
  for n in "$@"; do
    if [ "$d" = "$n" ] || [[ $d == *."$n" ]]; then return 0; fi
  done
  return 1
}
# Is $1 exactly one of the remaining arguments?
one_of(){
  local d=$1 n; shift
  for n in "$@"; do
    if [ "$d" = "$n" ]; then return 0; fi
  done
  return 1
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

# T3 Connect switch. agent-up mounts it READ-ONLY from the owner's config dir (.generated/t3-connect,
# from T3_CONNECT in project.conf); /etc/firewall is root-owned, so the agent can neither edit nor
# create it. Deliberately NOT an environment variable: sudo resets the environment, and the agent
# controls its own. Anything but the three exact values aborts here, before any change.
T3_CONNECT_FILE=/etc/firewall/t3-connect
T3_CONNECT=0
if [ -e "$T3_CONNECT_FILE" ]; then
  case "$(cat "$T3_CONNECT_FILE" 2>/dev/null)" in
    T3_CONNECT=0) ;;
    T3_CONNECT=1) T3_CONNECT=1 ;;
    T3_CONNECT=publish) T3_CONNECT=publish ;;
    *) echo "ERROR: $T3_CONNECT_FILE must hold exactly T3_CONNECT=0, T3_CONNECT=1 or T3_CONNECT=publish"; exit 1 ;;
  esac
fi
# Profile switch: same pattern (agent-up writes .generated/profile from PROFILE in project.conf, and
# mounts it only for the research profile). Absent = builder.
PROFILE_FILE=/etc/firewall/profile
PROFILE=builder
if [ -e "$PROFILE_FILE" ]; then
  case "$(cat "$PROFILE_FILE" 2>/dev/null)" in
    PROFILE=builder) ;;
    PROFILE=research) PROFILE=research ;;
    *) echo "ERROR: $PROFILE_FILE must hold exactly PROFILE=builder or PROFILE=research"; exit 1 ;;
  esac
fi
# Research: never reachable, whatever the port. 0/8 "this network", RFC1918, 100.64/10 shared/CGNAT
# (Tailscale), 127/8 loopback (lo itself is accepted earlier), 169.254/16 link-local (cloud metadata),
# 192.0.0.0/24 IETF protocol assignments, 198.18/15 benchmarking, 224/4 multicast, 240/4 reserved
# (incl. the 255.255.255.255 broadcast).
RESEARCH_DENY=(0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24
               192.168.0.0/16 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4)
# RStudio Server switch: same mount, same rules (agent-up writes .generated/rstudio from RSTUDIO).
RSTUDIO_FILE=/etc/firewall/rstudio
RSTUDIO=0
if [ -e "$RSTUDIO_FILE" ]; then
  case "$(cat "$RSTUDIO_FILE" 2>/dev/null)" in
    RSTUDIO=0) ;;
    RSTUDIO=1) RSTUDIO=1 ;;
    *) echo "ERROR: $RSTUDIO_FILE must hold exactly RSTUDIO=0 or RSTUDIO=1"; exit 1 ;;
  esac
fi
RSTUDIO_PORT=8787
# FTP host list: same mount pattern (agent-up writes .generated/ftp-hosts from FTP_HOSTS, only when it
# is non-empty). Its domains are parsed and validated below, with the allowlist files.
FTP_HOSTS_FILE=/etc/firewall/ftp-hosts
FTP_PORT=21
FTP_CHAIN=AGENT_FTP                          # our own raw-table chain: the only thing we touch in raw
FTP_HELPER_SYS=/sys/module/nf_conntrack_ftp  # present when the host kernel has the helper (built in or loaded)
TUNNEL_DOMAIN=argotunnel.com   # cloudflared's edge: SRV _v2-origintunneld._tcp.argotunnel.com -> region*.v2.argotunnel.com
TUNNEL_PORT=7844

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
if [ "$T3_CONNECT" = 1 ] || [ "$T3_CONNECT" = publish ]; then
  RAW_DOMAINS+=(t3.codes)   # app./relay./clerk.t3.codes (the relay's OTLP trace host is NOT added)
fi
mapfile -t ALLOWED_DOMAINS < <(printf '%s\n' "${RAW_DOMAINS[@]}" | tr 'A-Z' 'a-z' | sort -u)
echo "Allowlist: ${#ALLOWED_DOMAINS[@]} domains from $(printf '%s ' "${ALLOWLIST_FILES[@]##*/}")"
TUNNEL_LISTED=0   # the owner also allowlisted argotunnel.com itself: one ipset= line names both sets
for d in "${ALLOWED_DOMAINS[@]}"; do
  if [ "$d" = "$TUNNEL_DOMAIN" ]; then TUNNEL_LISTED=1; fi
done
# FTP hosts: the same line-by-line parsing and the same DOMAIN_RE as the allowlist, every token
# checked before any change. A present file must name at least one host (agent-up never writes an
# empty one, so an empty file is a broken mount, not "off": abort like an empty switch file).
FTP_ON=0
FTP_DOMAINS=()
if [ -e "$FTP_HOSTS_FILE" ]; then
  RAW_FTP=()
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n+1))
    line=${line%$'\r'}; line=${line%%#*}
    [[ $line =~ ^[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]] || continue   # blank
    tok=${BASH_REMATCH[1]}
    if [[ ! $tok =~ $DOMAIN_RE ]]; then
      echo "ERROR: invalid FTP host in $FTP_HOSTS_FILE line $n: '$tok' (want a bare domain, e.g. webin2.ebi.ac.uk)"; exit 1
    fi
    RAW_FTP+=("$tok")
  done < "$FTP_HOSTS_FILE"
  if [ "${#RAW_FTP[@]}" -eq 0 ]; then
    echo "ERROR: $FTP_HOSTS_FILE names no host (remove FTP_HOSTS from project.conf to turn FTP off)"; exit 1
  fi
  if [ "$PROFILE" = research ]; then
    echo "ERROR: $FTP_HOSTS_FILE is for builder projects only (the research profile's egress is already open on every port)"; exit 1
  fi
  # The helper must exist BEFORE we change anything: without it the control connection would work
  # but every data connection would be rejected (nothing would expect it).
  if [ ! -d "$FTP_HELPER_SYS" ]; then
    echo "ERROR: FTP hosts are set but the kernel has no FTP conntrack helper ($FTP_HELPER_SYS missing). A container cannot load it: load it on the HOST: sudo modprobe nf_conntrack_ftp (WSL2 kernels have it built in)"; exit 1
  fi
  mapfile -t FTP_DOMAINS < <(printf '%s\n' "${RAW_FTP[@]}" | tr 'A-Z' 'a-z' | sort -u)
  # argotunnel.com has its own set and dnsmasq takes one ipset= line per name: keep the two apart.
  for d in "${FTP_DOMAINS[@]}"; do
    if covered_by "$d" "$TUNNEL_DOMAIN" || covered_by "$TUNNEL_DOMAIN" "$d"; then
      echo "ERROR: FTP host '$d' in $FTP_HOSTS_FILE overlaps $TUNNEL_DOMAIN (T3 Connect's tunnel edge), which is never an FTP host"; exit 1
    fi
  done
  if ! iptables -t raw -S OUTPUT >/dev/null 2>&1; then
    echo "ERROR: FTP hosts are set but the iptables raw table is unavailable (needed to attach the FTP helper)"; exit 1
  fi
  FTP_ON=1
fi

if [ "$PROFILE" = research ]; then
  echo "Profile: research (open egress to public IPv4 on any port; private, local and reserved ranges denied; DNS not restricted)"
fi
if [ "$T3_CONNECT" = 1 ] && [ "$PROFILE" = research ]; then
  echo "T3 Connect: ON (research: open egress already covers t3.codes and the tunnel edge on $TUNNEL_PORT)"
elif [ "$T3_CONNECT" = 1 ]; then
  echo "T3 Connect: ON (t3.codes allowlisted; $TUNNEL_DOMAIN on port $TUNNEL_PORT only)"
elif [ "$T3_CONNECT" = publish ] && [ "$PROFILE" = research ]; then
  echo "T3 Connect: publish-only (research: open egress already covers t3.codes)"
elif [ "$T3_CONNECT" = publish ]; then
  echo "T3 Connect: publish-only (t3.codes allowlisted; no tunnel edge)"
else
  echo "T3 Connect: off"
fi
if [ "$RSTUDIO" = 1 ]; then
  echo "RStudio Server: ON (inbound tcp $RSTUDIO_PORT from the gateway only)"
else
  echo "RStudio Server: off"
fi
if [ "$FTP_ON" = 1 ]; then
  ftp_list=$(printf '%s ' "${FTP_DOMAINS[@]}")
  echo "FTP: ON (hosts ${ftp_list% }; tcp $FTP_PORT + conntrack ftp helper)"
else
  echo "FTP: off"
fi

# GitHub meta supplied by the host (CI only, so dozens of test containers do not each spend the
# unauthenticated api.github.com rate limit). Like the switches above it can only be a host mount:
# /etc/firewall is root-owned. Production never mounts it, and then the ranges are fetched live
# below. Its ranges pass exactly the same checks as fetched ones; anything malformed aborts here.
GH_META_FILE=/etc/firewall/github-meta.json
GH_META_FROM_FILE=0
if [ -e "$GH_META_FILE" ] || [ -L "$GH_META_FILE" ]; then
  [ -f "$GH_META_FILE" ] && [ ! -L "$GH_META_FILE" ] || { echo "ERROR: $GH_META_FILE must be a regular file"; exit 1; }
  gh_ranges=$(cat "$GH_META_FILE")
  if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null 2>&1; then
    echo "ERROR: $GH_META_FILE is not GitHub meta JSON with web, api and git ranges"; exit 1
  fi
  GH_META_FROM_FILE=1
  echo "GitHub meta: from $GH_META_FILE (supplied by the host; not fetched)"
fi

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

# The container's gateway = the Docker host side of its network. The ONE inbound exception (the T3
# Code server, container port 3773, published by compose on the host's 127.0.0.1 only) is accepted
# from this address alone: not from sibling containers, not from anywhere else.
T3_PORT=3773
GATEWAY_IP=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
[[ $GATEWAY_IP =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "ERROR: no IPv4 default gateway found (got '$GATEWAY_IP')"; exit 1; }
echo "Gateway (host side) detected as: $GATEWAY_IP"
# Research: the container's own networks (Docker's, whatever address pool they came from) are denied too.
OWN_NETS=()
if [ "$PROFILE" = research ]; then
  mapfile -t OWN_NETS < <(ip -4 route show scope link 2>/dev/null | awk '{print $1}' | sort -u)
  for n in "${OWN_NETS[@]}"; do
    [[ $n =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]] || { echo "ERROR: unexpected link route '$n'"; exit 1; }
  done
  echo "Research: own network(s) denied: $(printf '%s ' "${OWN_NETS[@]}")+ gateway $GATEWAY_IP"
fi

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
# raw: NOT flushed (nothing of ours lives there unless FTP was on). Remove only our own FTP chain,
# if a previous run created it (FTP on before, maybe off now), so a re-run never keeps a stale helper
# rule. Its ipset (below) can only be destroyed once no rule references it. Without the chain, raw is
# not touched at all: the FTP-off rules are exactly the ones without the feature.
raw_rules=$(iptables-save -t raw 2>/dev/null || true)   # captured: a grep -q on the pipe could SIGPIPE it (pipefail)
if grep -q "^:$FTP_CHAIN " <<<"$raw_rules"; then
  while iptables -t raw -D OUTPUT -j "$FTP_CHAIN" 2>/dev/null; do :; done
  iptables -t raw -F "$FTP_CHAIN"
  iptables -t raw -X "$FTP_CHAIN"
fi
# Kill connections opened before the firewall (or under a previous ruleset): without this their
# conntrack entries would keep matching the ESTABLISHED rule below.
conntrack -F >/dev/null
# Re-run: stop the previous dnsmasq (old config) and wait until 127.0.0.1:53 is free.
pkill -x dnsmasq 2>/dev/null || true
for _ in $(seq 1 50); do pgrep -x dnsmasq >/dev/null || break; sleep 0.1; done
ipset destroy allowed-domains 2>/dev/null || true
ipset destroy t3-tunnel 2>/dev/null || true
ipset destroy ftp-hosts 2>/dev/null || true

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

if [ "$GH_META_FROM_FILE" = 0 ]; then
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
fi

ipset create allowed-domains hash:net
if [ "$T3_CONNECT" = 1 ]; then
  ipset create t3-tunnel hash:net   # argotunnel.com's addresses ONLY (filled by dnsmasq)
fi
if [ "$FTP_ON" = 1 ]; then
  ipset create ftp-hosts hash:net   # the owner's FTP hosts' addresses ONLY (filled by dnsmasq; tcp 21 only)
fi

if [ "$GH_META_FROM_FILE" = 0 ]; then
  echo "Fetching GitHub IP ranges..."
  # --resolve pins curl to exactly the IPs allowed above. The status code and the headers are kept,
  # so a refusal (e.g. the unauthenticated rate limit: HTTP 403/429) is reported as what it is.
  GH_RESOLVE="api.github.com:443:$(IFS=,; echo "${SETUP_GH_IPS[*]}")"
  gh_hdrs=$(mktemp)
  gh_out=$(curl -q -sS --connect-timeout 10 --max-time 30 --resolve "$GH_RESOLVE" -D "$gh_hdrs" \
    -w '\n%{http_code}' https://api.github.com/meta) || gh_out=$'\n000'
  gh_code=${gh_out##*$'\n'}; gh_ranges=${gh_out%$'\n'*}
  gh_limit=$(awk -F': *' 'tolower($1)=="x-ratelimit-remaining"{gsub(/[^0-9]/,"",$2); print $2}' "$gh_hdrs")
  gh_reset=$(awk -F': *' 'tolower($1)=="x-ratelimit-reset"{gsub(/[^0-9]/,"",$2); print $2}' "$gh_hdrs")
  rm -f "$gh_hdrs"
  if [ "$gh_code" = 000 ]; then
    echo "ERROR: Failed to fetch GitHub IP ranges (no HTTP answer from api.github.com)"; exit 1
  fi
  if [ "$gh_code" != 200 ]; then
    # GitHub's own message, as plain printable text, truncated: it is only logged.
    gh_msg=$(echo "$gh_ranges" | jq -r '.message? // empty' 2>/dev/null | head -c 200 | tr -cd '[:print:]' || true)
    echo "ERROR: api.github.com/meta answered HTTP $gh_code${gh_msg:+: $gh_msg}${gh_limit:+ (rate limit remaining: $gh_limit${gh_reset:+, resets $(date -u -d "@$gh_reset" +%H:%M:%SZ 2>/dev/null)})}"
    exit 1
  fi
  if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
    echo "ERROR: GitHub API response missing required fields"; exit 1
  fi
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
  for d in "${ALLOWED_DOMAINS[@]}"; do
    sets=allowed-domains
    if [ "$T3_CONNECT" = 1 ] && [ "$d" = "$TUNNEL_DOMAIN" ]; then sets+=,t3-tunnel; fi
    # An allowlisted name that is (or is under) an FTP host: its own line must name ftp-hosts too.
    if [ "$FTP_ON" = 1 ] && covered_by "$d" "${FTP_DOMAINS[@]}"; then sets+=,ftp-hosts; fi
    echo "ipset=/$d/$sets"
  done
  # T3 Connect: argotunnel.com resolves (all record types, so cloudflared's SRV lookup works), and its
  # addresses land in t3-tunnel ONLY. dnsmasq adds the A records of each lookup of a name under it,
  # i.e. cloudflared's own lookups of the SRV targets.
  if [ "$T3_CONNECT" = 1 ] && [ "$TUNNEL_LISTED" = 0 ]; then
    echo "server=/$TUNNEL_DOMAIN/$UPSTREAM_DNS"
    echo "ipset=/$TUNNEL_DOMAIN/t3-tunnel"
  fi
  # FTP hosts: they resolve (dnsmasq forwards them) and their addresses land in ftp-hosts, open on
  # tcp 21 only. One line per name: a name already on the allowlist got ftp-hosts on its line above;
  # an FTP host under an allowlisted name keeps allowed-domains on its own line (longest match wins).
  if [ "$FTP_ON" = 1 ]; then
    for d in "${FTP_DOMAINS[@]}"; do
      if one_of "$d" "${ALLOWED_DOMAINS[@]}"; then continue; fi
      echo "server=/$d/$UPSTREAM_DNS"
      if covered_by "$d" "${ALLOWED_DOMAINS[@]}"; then echo "ipset=/$d/allowed-domains,ftp-hosts"; else echo "ipset=/$d/ftp-hosts"; fi
    done
  fi
} > "$DNSMASQ_CONF.tmp"
if [ "$PROFILE" = research ]; then
  # Research: every name resolves (one default server), still only through dnsmasq's uid; no ipsets.
  printf 'no-resolv\nuser=dnsmasq\nlisten-address=127.0.0.1\nbind-interfaces\nserver=%s\n' "$UPSTREAM_DNS" > "$DNSMASQ_CONF.tmp"
fi
chmod 0644 "$DNSMASQ_CONF.tmp"
mv "$DNSMASQ_CONF.tmp" "$DNSMASQ_CONF"
dnsmasq --conf-file="$DNSMASQ_CONF"

# Route all in-container DNS through dnsmasq.
echo "nameserver 127.0.0.1" > /etc/resolv.conf

# Prime the ipset for the allowlisted domains (also a dnsmasq sanity check). Builder only.
if [ "$PROFILE" = builder ]; then
  for domain in "${ALLOWED_DOMAINS[@]}"; do
    dig -r +short "$domain" @127.0.0.1 >/dev/null 2>&1 || true
  done
fi
if [ "$FTP_ON" = 1 ]; then   # builder only (research aborted above)
  for domain in "${FTP_DOMAINS[@]}"; do
    dig -r +short "$domain" @127.0.0.1 >/dev/null 2>&1 || true
  done
fi
if [ "$PROFILE" = builder ] && [ "$T3_CONNECT" = 1 ]; then   # the edge targets cloudflared will pick (it looks them up itself anyway)
  for t in $(dig -r +short +time=3 +tries=2 SRV "_v2-origintunneld._tcp.$TUNNEL_DOMAIN" @127.0.0.1 2>/dev/null | awk '{print $4}' || true); do
    dig -r +short "$t" @127.0.0.1 >/dev/null 2>&1 || true
  done
fi

# T3 Code server: inbound from the host side (gateway) only; replies leave via ESTABLISHED.
iptables -A INPUT -s "$GATEWAY_IP" -p tcp --dport "$T3_PORT" -j ACCEPT
# RStudio Server, only where the owner enabled it: the same pattern, its own port.
if [ "$RSTUDIO" = 1 ]; then
  iptables -A INPUT -s "$GATEWAY_IP" -p tcp --dport "$RSTUDIO_PORT" -j ACCEPT
fi
if [ "$PROFILE" = builder ]; then
  # Only allowlisted destinations, only on SSH/HTTP/HTTPS.
  iptables -A OUTPUT -p tcp -m set --match-set allowed-domains dst -m multiport --dports 22,80,443 -j ACCEPT
  # T3 Connect only: cloudflared to Cloudflare's tunnel edge, port 7844 (QUIC/UDP, HTTP2/TCP), and
  # only to the t3-tunnel set: no other allowlisted host gets 7844, and argotunnel gets nothing else.
  if [ "$T3_CONNECT" = 1 ]; then
    iptables -A OUTPUT -p udp --dport "$TUNNEL_PORT" -m set --match-set t3-tunnel dst -j ACCEPT
    iptables -A OUTPUT -p tcp --dport "$TUNNEL_PORT" -m set --match-set t3-tunnel dst -j ACCEPT
  fi
  # FTP only: the owner's FTP hosts, control connection on tcp 21 and nothing else. The raw-table
  # rule attaches the kernel's FTP helper to exactly those connections; it parses the EPSV/PASV reply
  # and expects the data connection, which the ESTABLISHED,RELATED accept above then lets out. No
  # other host gets 21, and the FTP hosts get no other port (no high-port range is ever opened).
  if [ "$FTP_ON" = 1 ]; then
    iptables -t raw -N "$FTP_CHAIN"
    iptables -t raw -A "$FTP_CHAIN" -p tcp --dport "$FTP_PORT" -m set --match-set ftp-hosts dst -j CT --helper ftp
    iptables -t raw -A OUTPUT -j "$FTP_CHAIN"
    iptables -A OUTPUT -p tcp --dport "$FTP_PORT" -m set --match-set ftp-hosts dst -j ACCEPT
  fi
else
  # Research: the denied ranges FIRST, then any public IPv4 destination on any TCP/UDP port.
  for n in "${RESEARCH_DENY[@]}" "${OWN_NETS[@]}" "$GATEWAY_IP/32"; do
    iptables -A OUTPUT -d "$n" -j REJECT --reject-with icmp-admin-prohibited
  done
  iptables -A OUTPUT -p tcp -j ACCEPT
  iptables -A OUTPUT -p udp -j ACCEPT
fi
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
n_tunnel=$(iptables -S OUTPUT | grep -c -- "--dport $TUNNEL_PORT -m set --match-set t3-tunnel dst -j ACCEPT" || true)
if [ "$PROFILE" = research ]; then
  # Every denied range must be in place (and before the open ACCEPTs, which come last by construction).
  for n in "${RESEARCH_DENY[@]}" "${OWN_NETS[@]}" "$GATEWAY_IP/32"; do
    iptables -C OUTPUT -d "$n" -j REJECT --reject-with icmp-admin-prohibited 2>/dev/null \
      || { echo "ERROR: Firewall verification failed - research deny rule for $n is missing"; exit 1; }
  done
  if [ "$n_tunnel" != 0 ] || iptables -S OUTPUT | grep -q -- '--match-set'; then
    echo "ERROR: Firewall verification failed - research profile has an ipset rule"; exit 1
  fi
  if curl -q --connect-timeout 5 "http://$GATEWAY_IP/" >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - research reached the gateway $GATEWAY_IP"; exit 1
  fi
  echo "Firewall verification passed - research: private, local and reserved ranges + gateway denied"
elif [ "$T3_CONNECT" = 1 ] && [ "$n_tunnel" != 2 ]; then
  echo "ERROR: Firewall verification failed - T3 Connect is on but the $TUNNEL_PORT rules are missing ($n_tunnel of 2)"; exit 1
fi
if { [ "$T3_CONNECT" = 0 ] || [ "$T3_CONNECT" = publish ]; } && iptables -S OUTPUT | grep -q -- "--dport $TUNNEL_PORT"; then
  echo "ERROR: Firewall verification failed - T3 Connect is off or publish-only but a $TUNNEL_PORT rule is present"; exit 1
fi
# FTP: on = exactly one tcp 21 rule in OUTPUT (the ftp-hosts ACCEPT), exactly one jump to our raw chain
# and exactly one helper rule in it; off = no tcp 21 rule, no helper rule anywhere in raw, no chain.
n_ftp_any=$(iptables -S OUTPUT | grep -cE -- "--dport $FTP_PORT( |\$)" || true)
n_ftp=$(iptables -S OUTPUT | grep -c -- "--dport $FTP_PORT -m set --match-set ftp-hosts dst -j ACCEPT" || true)
raw_rules=$(iptables-save -t raw 2>/dev/null || true)
n_ftp_jump=$(grep -cx -- "-A OUTPUT -j $FTP_CHAIN" <<<"$raw_rules" || true)
n_ftp_helper=$(grep -c -- "--helper ftp" <<<"$raw_rules" || true)
n_ftp_helper_ours=$(grep -cE -- "^-A $FTP_CHAIN -p tcp -m tcp --dport $FTP_PORT -m set --match-set ftp-hosts dst -j CT --helper ftp\$" <<<"$raw_rules" || true)
if [ "$FTP_ON" = 1 ]; then
  if [ "$n_ftp" != 1 ] || [ "$n_ftp_any" != 1 ] || [ "$n_ftp_jump" != 1 ] || [ "$n_ftp_helper" != 1 ] || [ "$n_ftp_helper_ours" != 1 ]; then
    echo "ERROR: Firewall verification failed - FTP is on but its rules are wrong (tcp $FTP_PORT ACCEPT $n_ftp of 1, any tcp $FTP_PORT $n_ftp_any of 1, raw jump $n_ftp_jump of 1, helper $n_ftp_helper_ours of 1, any helper $n_ftp_helper of 1)"; exit 1
  fi
elif [ "$n_ftp_any" != 0 ] || [ "$n_ftp_helper" != 0 ] || grep -q -- "$FTP_CHAIN" <<<"$raw_rules" \
     || grep -qx ftp-hosts <<<"$(ipset list -n 2>/dev/null || true)"; then
  echo "ERROR: Firewall verification failed - FTP is off but a tcp $FTP_PORT rule, an ftp helper rule, the $FTP_CHAIN chain or the ftp-hosts set is present"; exit 1
fi
n_rstudio=$(iptables -S INPUT | grep -c -- "--dport $RSTUDIO_PORT -j ACCEPT" || true)
if [ "$RSTUDIO" = 1 ] && [ "$n_rstudio" != 1 ]; then
  echo "ERROR: Firewall verification failed - RStudio Server is on but its INPUT rule is missing ($n_rstudio of 1)"; exit 1
fi
if [ "$RSTUDIO" = 0 ] && [ "$n_rstudio" != 0 ]; then
  echo "ERROR: Firewall verification failed - RStudio Server is off but a $RSTUDIO_PORT INPUT rule is present"; exit 1
fi
if [ "$PROFILE" = builder ]; then
  if curl -q --connect-timeout 5 https://1.1.1.1/ >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://1.1.1.1 (literal IP)"; exit 1
  fi
  if dig -r +short +time=3 +tries=1 example.com @127.0.0.1 2>/dev/null | grep -qE '^[0-9.]+$'; then
    echo "ERROR: Firewall verification failed - dnsmasq resolved non-allowlisted example.com"; exit 1
  fi
  echo "Firewall verification passed - literal IP blocked, non-allowlisted names not resolved"
elif dig -r +short +time=3 +tries=2 example.com @127.0.0.1 2>/dev/null | grep -qE '^[0-9.]+$'; then
  echo "Firewall verification passed - research: dnsmasq resolves any name (example.com)"
else   # soft, like CRAN: a transient DNS hiccup must not brick the start
  echo "WARNING: research profile but dnsmasq did not resolve example.com right now"
fi

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

if [ "$T3_CONNECT" = 1 ] && [ "$PROFILE" = builder ]; then   # soft, like CRAN below: T3 Connect being down must not brick the start
  if [ -n "$(dig -r +short +time=3 +tries=2 SRV "_v2-origintunneld._tcp.$TUNNEL_DOMAIN" @127.0.0.1 2>/dev/null)" ]; then
    echo "Firewall verification passed - T3 Connect tunnel edge discoverable (SRV via dnsmasq)"
  else
    echo "WARNING: T3 Connect is on but the tunnel edge SRV record did not resolve right now"
  fi
fi

# Soft check: a transient CRAN outage should not brick container startup, but a broken
# dynamic allowlist should be visible in the log.
if curl -q --connect-timeout 8 -sSf https://cloud.r-project.org/src/contrib/PACKAGES.gz >/dev/null 2>&1; then
  echo "Firewall verification passed - CRAN reachable via dnsmasq dynamic allowlist"
else
  echo "WARNING: could not reach CRAN (cloud.r-project.org) right now - if this persists, check dnsmasq/resolv.conf"
fi
