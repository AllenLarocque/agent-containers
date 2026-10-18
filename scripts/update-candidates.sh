#!/usr/bin/env bash
# List the pinned versions of T3, Claude Code and Codex, and every newer stable upstream version that
# is past the cooldown. Run from the repo root; a weekly agent reads the notes and judges each one.
#   PINNED<TAB><tool><TAB><version>                       (t3, claude-code, codex, t3-protocol)
#   NEW<TAB><tool><TAB><version><TAB><YYYY-MM-DD><TAB><notes-url>   (oldest first)
# Env: UPDATE_COOLDOWN_DAYS (default 2), UPDATE_NOW (epoch seconds, default now; tests pin it).
# Upstream responses are untrusted data: only versions and timestamps are extracted (never eval'd),
# and a version is printed only if it matches strict x.y.z.
set -euo pipefail

COOLDOWN_DAYS=${UPDATE_COOLDOWN_DAYS:-2}
NOW=${UPDATE_NOW:-$(date +%s)}
case $COOLDOWN_DAYS$NOW in *[!0-9]*|'') echo "update-candidates: UPDATE_COOLDOWN_DAYS and UPDATE_NOW must be integers" >&2; exit 1 ;; esac
CUTOFF=$((NOW - COOLDOWN_DAYS * 86400))
SEMVER='^[0-9]+\.[0-9]+\.[0-9]+$'

die() { echo "update-candidates: $*" >&2; exit 1; }

# pin_of <package.json> -> "<package> <version>" of its single dependency
pin_of() {
  jq -er '.dependencies | to_entries | if length == 1 then "\(.[0].key) \(.[0].value)" else error("expected one dependency") end' "$1" \
    || die "cannot read the pinned dependency in $1"
}

t3_ver=$(sed -n 's/^ARG T3_VERSION=\(.*\)$/\1/p' images/base/Dockerfile)
t3_proto=$(sed -n 's/^ENV T3_PROTOCOL=\(.*\)$/\1/p' images/base/Dockerfile)
read -r cc_pkg cc_ver < <(pin_of images/base/agent-clis/claude-code/package.json)
read -r cx_pkg cx_ver < <(pin_of images/base/agent-clis/codex/package.json)
[[ $t3_ver =~ $SEMVER ]] || die "T3_VERSION '$t3_ver' in images/base/Dockerfile is not x.y.z"
[[ $t3_proto =~ ^[0-9]+$ ]] || die "T3_PROTOCOL '$t3_proto' in images/base/Dockerfile is not a number"
[[ $cc_ver =~ $SEMVER ]] || die "pinned $cc_pkg '$cc_ver' is not x.y.z"
[[ $cx_ver =~ $SEMVER ]] || die "pinned $cx_pkg '$cx_ver' is not x.y.z"

printf 'PINNED\tt3\t%s\nPINNED\tclaude-code\t%s\nPINNED\tcodex\t%s\nPINNED\tt3-protocol\t%s\n' \
  "$t3_ver" "$cc_ver" "$cx_ver" "$t3_proto"

# emit <tool> <pin> <notes-url, @V@ replaced by the version> <version/epoch lines on stdin>
# Keeps strict-semver versions newer than the pin and published at or before the cutoff.
emit() {
  local tool=$1 pin=$2 url=$3 v ep
  while IFS=$'\t' read -r v ep; do
    [[ $v =~ $SEMVER && $ep =~ ^[0-9]+$ ]] || continue
    [ "$v" != "$pin" ] || continue
    [ "$(printf '%s\n%s\n' "$pin" "$v" | sort -V | tail -n 1)" = "$v" ] || continue
    [ "$ep" -le "$CUTOFF" ] || continue
    printf '%s\t%s\t%s\n' "$v" "$(date -u -d "@$ep" +%F)" "${url//@V@/$v}"
  done | sort -V -k1,1 | while IFS=$'\t' read -r v d url; do
    printf 'NEW\t%s\t%s\t%s\t%s\n' "$tool" "$v" "$d" "$url"
  done
}

# ISO 8601 (optionally with fractional seconds) -> epoch, in jq; unparsable stamps are dropped.
EPOCH='(try (sub("\\.[0-9]+";"") | fromdateiso8601) catch empty)'

q='repos/pingdotgg/t3code/releases?per_page=100'
raw=$(gh api "$q") || die "gh api '$q' failed"
rows=$(jq -r "
  .[] | select(.prerelease == false and .draft == false and (.tag_name | test(\"^v[0-9]+\\\\.[0-9]+\\\\.[0-9]+\$\")))
  | (.published_at | $EPOCH) as \$e | select(\$e != null) | \"\(.tag_name | ltrimstr(\"v\"))\t\(\$e)\"" <<<"$raw") \
  || die "cannot parse the response of gh api '$q'"
emit t3 "$t3_ver" "https://github.com/pingdotgg/t3code/releases/tag/v@V@" <<<"$rows"

npm_new() { # npm_new <tool> <package> <pin> <url>
  local raw rows
  raw=$(npm view "$2" time --json) || die "npm view $2 time --json failed"
  rows=$(jq -r "
    to_entries[] | select(.key != \"created\" and .key != \"modified\" and (.key | contains(\"-\") | not))
    | (.value | $EPOCH) as \$e | select(\$e != null) | \"\(.key)\t\(\$e)\"" <<<"$raw") \
    || die "cannot parse the response of npm view $2 time --json"
  emit "$1" "$3" "$4" <<<"$rows"
}
npm_new claude-code "$cc_pkg" "$cc_ver" "https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md"
npm_new codex "$cx_pkg" "$cx_ver" "https://github.com/openai/codex/releases/tag/rust-v@V@"
