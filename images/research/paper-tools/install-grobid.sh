#!/usr/bin/env bash
# Configure the GROBID copied (COPY --from the digest-pinned image) to /opt/paper-tools/grobid, and
# install the `grobid` wrapper (bin/grobid next to this script) to /usr/local/bin/grobid.
#   grobid-home/config/grobid.yaml: concurrency 2, pdfalto memoryLimitMb 2048, every HTTP connector
#     bound to 127.0.0.1 (port 8070, localhost only). Anchored edits; any key not where expected
#     fails the build, with the relevant yaml lines and directory listings printed.
#   non-lin-64 pdfalto/ and lib/ architecture dirs are deleted; grobid-home/tmp is made writable.
#   appends "grobid: <image-ref> (CRF only, consolidation off)" to /opt/paper-tools/MANIFEST.
# Runs after install.sh (which writes the MANIFEST). Usage: install-grobid.sh <image-ref>
set -euo pipefail
ref=${1:?GROBID image ref, e.g. grobid/grobid:0.9.1-crf@sha256:...}
[[ $ref =~ ^[^[:space:]]+$ ]] || { echo "install-grobid: bad image ref '$ref'" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
out=/opt/paper-tools
g=$out/grobid
cfg=$g/grobid-home/config/grobid.yaml

context() {  # everything needed to fix a wrong layout assumption from one CI log
  echo "--- context ---" >&2
  ls -la "$g" "$g/grobid-home" "$g/grobid-home/config" "$g/grobid-home/pdfalto" "$g/grobid-home/lib" \
    "$g/grobid-service" "$g/grobid-service/bin" >&2 2>&1 || true
  if [ -f "$cfg" ]; then
    echo "--- $cfg (relevant keys) ---" >&2
    grep -nE '^[^ #]|concurrency|memoryLimitMb|pdfalto|server:|onnectors|type:|port:|bindHost|temp:|currentLogFilename' "$cfg" >&2 || true
  fi
}
fail() { echo "install-grobid: FAIL: $*" >&2; context; exit 1; }

[ -f "$out/MANIFEST" ] || fail "$out/MANIFEST missing: install.sh must run first"
[ -x "$g/grobid-service/bin/grobid-service" ] || fail "no executable $g/grobid-service/bin/grobid-service"
[ -f "$cfg" ] || fail "no $cfg"
[ -d "$g/grobid-home/pdfalto/lin-64" ] || fail "no $g/grobid-home/pdfalto/lin-64"
[ -d "$g/grobid-home/lib/lin-64" ] || fail "no $g/grobid-home/lib/lin-64"

# yaml_child <file> <parent> <key> [<int>]: the integer <key> that is a DIRECT child of the first
# `<parent>:` mapping. Without <int>, print its value; with <int>, print the file with it replaced.
# Exits 3 unless exactly one such line exists.
yaml_child() {
  awk -v parent="$2" -v key="$3" -v val="${4-}" '
    function ind(s) { match(s, /^ */); return RLENGTH }
    {
      if (st == 0 && $0 ~ ("^ *" parent ":[ ]*(#.*)?$")) { st = 1; pi = ind($0) }
      else if (st == 1 && $0 !~ /^ *(#.*)?$/) {          # skip blank and comment lines
        if (ind($0) <= pi) st = 2                         # left the parent block
        else {
          if (ci == "") ci = ind($0)                      # indent of the direct children
          if (ind($0) == ci && $0 ~ ("^ *" key ":[ ]*[0-9]+[ ]*(#.*)?$")) {
            n++; v = $0; sub("^ *" key ":[ ]*", "", v); sub(/[ ]*(#.*)?$/, "", v)
            if (val != "") sub(key ":[ ]*[0-9]+", key ": " val)
          }
        }
      }
      if (val != "") print
    }
    END { if (n != 1) exit 3; if (val == "") print v }' "$1"
}

set_int() {  # set_int <parent> <key> <int>: edit grobid.yaml in place, then read it back
  local tmp got
  tmp=$(mktemp "$cfg.XXXXXX")
  if ! yaml_child "$cfg" "$1" "$2" "$3" > "$tmp"; then
    rm -f "$tmp"; fail "expected exactly one '$2: <integer>' directly under '$1:' in $cfg"
  fi
  chmod 0644 "$tmp"; mv -f "$tmp" "$cfg"
  got=$(yaml_child "$cfg" "$1" "$2") || fail "$1.$2 not found after the edit"
  [ "$got" = "$3" ] || fail "$1.$2 is '$got' after the edit, expected $3"
  echo "grobid.yaml: $1.$2 = $got"
}
set_int grobid concurrency 2
set_int pdfalto memoryLimitMb 2048

# Localhost only: add `bindHost: 127.0.0.1` to every `- type: http` connector (application 8070, admin).
n=$(grep -cE '^[[:space:]]*- type: http[[:space:]]*$' "$cfg" || true)
[ "$n" -ge 1 ] || fail "no '- type: http' connector lines in $cfg"
! grep -qE '^[[:space:]]*bindHost:' "$cfg" || fail "$cfg already has a bindHost; check it by hand"
grep -qE '^[[:space:]]*port: 8070[[:space:]]*$' "$cfg" || fail "no 'port: 8070' in $cfg"
tmp=$(mktemp "$cfg.XXXXXX")
sed -E 's/^([[:space:]]*)- type: http[[:space:]]*$/&\n\1  bindHost: 127.0.0.1/' "$cfg" > "$tmp" || { rm -f "$tmp"; fail "sed failed"; }
chmod 0644 "$tmp"; mv -f "$tmp" "$cfg"
b=$(grep -cE '^[[:space:]]*bindHost: 127\.0\.0\.1$' "$cfg" || true)
[ "$b" -eq "$n" ] || fail "$b bindHost lines for $n connectors"
echo "grobid.yaml: $n http connector(s) bound to 127.0.0.1"

# Only linux x86-64 native code is used; drop the other architecture dirs.
for d in "$g/grobid-home/pdfalto"/* "$g/grobid-home/lib"/*; do
  [ -d "$d" ] || continue
  case ${d##*/} in
    lin-64) ;;
    lin-*|lin_*|mac-*|mac_*|win-*|win_*) rm -rf -- "$d"; echo "removed ${d#"$g"/}" ;;
  esac
done

mkdir -p "$g/grobid-home/tmp"
chmod -R a+rX "$g"
chmod -R a+rwX "$g/grobid-home/tmp"
install -m 0755 "$here/bin/grobid" /usr/local/bin/grobid
printf 'grobid: %s (CRF only, consolidation off)\n' "$ref" >> "$out/MANIFEST"
echo "grobid: installed $ref"
