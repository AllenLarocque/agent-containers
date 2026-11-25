#!/usr/bin/env bash
# Tests for bin/agent-inputs scan (spec docs/superpowers/specs/2026-11-25-shared-inputs-design.md §3).
# Fake HOME in a temp dir with two builder configs (p1, p2) and one research config. Every case builds
# a fresh fixture: 2 MiB random files, modified 3 days ago, last read 400 days ago, unless it says
# otherwise. The projects live under the fake HOME so "no host home path in the report" means something.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AI_BIN="$ROOT/bin/agent-inputs"
fail=0
check(){ # $1 label, rest = command that must succeed
  local d="$1" o; shift
  if o=$("$@" 2>&1); then echo "OK:   $d"; else echo "FAIL: $d"; printf '%s\n' "$o" | sed 's/^/        /'; annotate "$d"; fail=1; fi
}
refuses(){ # $1 label, $2 ERE the message must match, rest = command that must FAIL
  local d="$1" re="$2" rc=0 msg; shift 2
  msg=$("$@" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ] && grep -Eq -- "$re" <<<"$msg"; then echo "OK:   $d"
  else echo "FAIL: $d (rc=$rc, want non-zero and /$re/)"; printf '%s\n' "$msg" | sed 's/^/        /'; annotate "$d"; fail=1; fi
}
annotate(){ [ -z "${GITHUB_ACTIONS:-}" ] || echo "::error title=agent-inputs test::FAIL: $1"; }

T="$(mktemp -d)"
SHM=""
cleanup(){ chmod -R u+rwX "$T" 2>/dev/null || true; rm -rf "$T"; [ -z "$SHM" ] || rm -rf "$SHM"; }
trap cleanup EXIT
H="$T/home"; CFG="$H/.config/agent-containers"; STATE="$H/.local/state/agent-containers/inputs.json"
P1="$H/GitHub/p1"; P2="$H/GitHub/p2"; OUT="$T/outside"
MIB=1048576

ai(){ HOME="$H" "$AI_BIN" "$@"; }
scan(){ # a run that must succeed; a failure is reported and the suite carries on
  local rc=0; ai scan "$@" >/dev/null || rc=$?
  [ "$rc" -eq 0 ] || { echo "FAIL: scan $* exited $rc"; annotate "scan exited $rc"; fail=1; }
}
scan2(){ # config refusal: passes (returns non-zero) only with exit code 2
  local rc=0; ai scan || rc=$?
  [ "$rc" -eq 2 ] && return 2
  echo "exit $rc, want 2"; return 0
}
mkf(){ # $1 path, $2 bytes (default 2 MiB), $3 mtime (default 3 days ago), $4 atime (default 400 days ago)
  mkdir -p "$(dirname "$1")"; head -c "${2:-$((2*MIB))}" /dev/urandom > "$1"; settime "$@"
}
dup(){ # $1 source, $2 copy, $3 mtime, $4 atime (copying reads the source: its atime is put back)
  local sa; sa="$(stat -c %X "$1")"
  mkdir -p "$(dirname "$2")"; cp "$1" "$2"; touch -a -d "@$sa" "$1"; settime "$2" "" "${3:-}" "${4:-}"
}
settime(){ touch -m -d "${3:-3 days ago}" "$1"; touch -a -d "${4:-400 days ago}" "$1"; }
ino(){ stat -c %i "$1"; }
nsum(){ # SHA-256 of a file read with O_NOATIME, so checking a file leaves its atime alone
  python3 -c 'import hashlib,os,sys; fd=os.open(sys.argv[1], os.O_RDONLY|os.O_NOATIME); h=hashlib.sha256()
while (b := os.read(fd, 1 << 20)): h.update(b)
print(h.hexdigest())' "$1"
}
export -f nsum
conf(){ printf '%s\n' "$@" > "$CFG/inputs.conf"; }
fresh(){ # new project folders, no state, no reports
  chmod -R u+rwX "$H/GitHub" 2>/dev/null || true
  rm -rf "$H/GitHub" "$OUT" "$H/.local"; mkdir -p "$P1" "$P2" "$OUT"
}
section(){ # $1 heading text (part of a "## " line), $2 report: the lines under that heading
  awk -v h="$1" '/^## /{p=index($0,h)>0; next} p' "$2"
}
export -f section
state(){ # $1 section, $2 key
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sections"][sys.argv[2]][sys.argv[3]])' "$STATE" "$1" "$2" 2>/dev/null || echo "(no state)"
}

mkdir -p "$CFG/p1" "$CFG/p2" "$CFG/research"
printf 'PROJECT=p1\nPROFILE=builder\nPROJECT_DIR=%s\n' "$P1" > "$CFG/p1/project.conf"
printf 'PROJECT=p2\nPROFILE=builder\nPROJECT_DIR=%s\n' "$P2" > "$CFG/p2/project.conf"
printf 'PROJECT=research\nPROFILE=research\nRESEARCH_DIR=%s\n' "$P1/research-dl" > "$CFG/research/project.conf"

check "bin/agent-inputs exists and is executable" test -x "$AI_BIN"

# ---- linking
fresh; mkf "$P1/data/a.bin"; dup "$P1/data/a.bin" "$P1/data2/a.bin"
conf "[p1]" data data2
scan
check "identical files in two folders become one inode, read-only" bash -c '
  [ "$(stat -c %i "$1")" = "$(stat -c %i "$2")" ] && [ "$(stat -c %h "$1")" = 2 ] && ! stat -c %A "$1" | grep -q w' _ "$P1/data/a.bin" "$P1/data2/a.bin"

fresh
mkf "$P1/data/c1.bin"; mkf "$P1/data2/c2.bin"                                   # same size, different content
mkf "$P1/data/s1.bin" $((512*1024)); dup "$P1/data/s1.bin" "$P1/data2/s1.bin"   # under 1 MiB
mkf "$P1/data/t1.bin" "" now; dup "$P1/data/t1.bin" "$P1/data2/t1.bin" now      # modified today
mkf "$OUT/target.bin"; dup "$OUT/target.bin" "$P1/data/real.bin"; ln -s "$OUT/target.bin" "$P1/data2/link.bin"
mkdir -p "$P1/data/.git"; dup "$P1/data/real.bin" "$P1/data/.git/obj.bin"         # .git skipped
before="$(stat -c '%i %h %a' "$P1"/data/*.bin "$P1"/data2/*.bin "$P1/data/.git/obj.bin" "$OUT/target.bin")"
conf "[p1]" data data2
scan
check "different content, files under 1 MiB, files modified today and symlinks are left alone" bash -c '
  [ "$(stat -c "%i %h %a" "$1"/data/*.bin "$1"/data2/*.bin "$1/data/.git/obj.bin" "$2")" = "$3" ] && [ -L "$1/data2/link.bin" ]' _ "$P1" "$OUT/target.bin" "$before"

fresh; mkf "$P1/data/a.bin"; dup "$P1/data/a.bin" "$P1/data2/a.bin"
ln "$P1/data2/a.bin" "$P1/data2/.agent-inputs-tmp-x"   # a leftover temp link: a dry run leaves it too
before="$(stat -c '%i %h %a %Y %X' "$P1/data/a.bin" "$P1/data2/a.bin" "$P1/data2/.agent-inputs-tmp-x")"
conf "[p1]" data data2
dryout="$(ai scan --dry-run)" || true
check "dry run changes no inode, mtime or atime and writes the report" bash -c '
  [ "$(stat -c "%i %h %a %Y %X" "$1/data/a.bin" "$1/data2/a.bin" "$1/data2/.agent-inputs-tmp-x")" = "$2" ] && [ -f "$1/data/REPORT.md" ] && grep -q "dry run" "$1/data/REPORT.md" &&
  grep -q "data2/a.bin" <<<"$3" && [ "$(python3 -c "import json,sys; d=json.load(open(sys.argv[1]))[\"sections\"][\"p1\"]; print(d[\"dry_run\"], d[\"freed_bytes_run\"], d[\"freed_bytes_total\"])" "$4")" = "True 2097152 0" ]' \
  _ "$P1" "$before" "$dryout" "$STATE"

fresh; mkf "$P1/data/c1.bin"; mkf "$P1/data2/c2.bin"
before="$(stat -c %X "$P1/data/c1.bin" "$P1/data2/c2.bin")"
conf "[p1]" data data2
scan
check "scan does not change atime of files it read" bash -c '[ "$(stat -c %X "$1" "$2")" = "$3" ]' _ "$P1/data/c1.bin" "$P1/data2/c2.bin" "$before"

fresh; mkf "$P1/data/a.bin" "" "5 days ago" "400 days ago"; dup "$P1/data/a.bin" "$P1/data2/a.bin" "3 days ago" "10 days ago"
want="$(stat -c %X "$P1/data2/a.bin") $(stat -c %Y "$P1/data/a.bin")"; kept="$(ino "$P1/data/a.bin")"
conf "[p1]" data data2
scan
check "kept inode gets the group's latest atime and keeps its mtime" bash -c '
  [ "$(stat -c %i "$1")" = "$3" ] && [ "$(stat -c %i "$2")" = "$3" ] && [ "$(stat -c "%X %Y" "$1")" = "$4" ]' _ "$P1/data/a.bin" "$P1/data2/a.bin" "$kept" "$want"

# ---- the report
fresh; mkf "$P1/data/a.bin"; dup "$P1/data/a.bin" "$P1/data2/a.bin"; mkf "$P1/data/recent.bin" "" "" "2 days ago"
conf "[p1]" data data2
scan
check "old-files section lists an old inode once with all its /workspace paths" bash -c '
  s="$(section "Not read in 180 days" "$1")"
  [ "$(grep -c "/workspace/data/a.bin" <<<"$s")" = 1 ] && grep "/workspace/data/a.bin" <<<"$s" | grep -q "/workspace/data2/a.bin" && ! grep -q recent.bin <<<"$s"' _ "$P1/data/REPORT.md"

fresh; mkf "$P1/inputs-shared/u.bin"; mkf "$P1/inputs-shared/d.bin"; dup "$P1/inputs-shared/d.bin" "$P1/data/d.bin"
conf "[p1]" "report = inputs-shared" data inputs-shared
scan
check "shared-folder section lists a link-count-1 file and not a linked one" bash -c '
  s="$(section "linked from nowhere else" "$1")"; grep -q "/workspace/inputs-shared/u.bin" <<<"$s" && ! grep -q "d.bin" <<<"$s"' _ "$P1/inputs-shared/REPORT.md"

fresh; mkf "$P1/data/g.bin"; dup "$P1/data/g.bin" "$P2/dataB/g.bin"
conf "[p1]" data "[p2]" dataB
scan
ok1=0; [ "$(ino "$P1/data/g.bin")" != "$(ino "$P2/dataB/g.bin")" ] || ok1=1
conf "[p1]" "group = shared" data "[p2]" "group = shared" dataB
scan
check "two sections in different groups never share an inode; same group do, and each report names the other container without its paths" bash -c '
  [ "$1" = 0 ] && [ "$(stat -c %i "$2/data/g.bin")" = "$(stat -c %i "$3/dataB/g.bin")" ] &&
  grep -q "/workspace/data/g.bin.*p2" "$2/data/REPORT.md" && ! grep -q dataB "$2/data/REPORT.md" &&
  grep -q "/workspace/dataB/g.bin.*p1" "$3/dataB/REPORT.md" && ! grep -q "/workspace/data/" "$3/dataB/REPORT.md"' _ "$ok1" "$P1" "$P2"

fresh; mkf "$P1/data/a.bin"; dup "$P1/data/a.bin" "$P1/data2/a.bin"; mkf "$P1/data/b.bin"; dup "$P1/data/b.bin" "$P1/data2/b.bin"
conf "[p1]" data data2
scan
first="$(state p1 freed_bytes_total) $(state p1 total_bytes)"; inodes="$(stat -c %i "$P1"/data*/*.bin)"
scan
check "second scan links nothing, totals stable" bash -c '
  [ "$1" = "4194304 4194304" ] && [ "$(stat -c %i "$2"/data*/*.bin)" = "$3" ] && [ "$4" = "0 4194304 4194304" ] && [ -f "$2/data/REPORT.md" ] &&
  ! section "linked from nowhere else" "$2/data/REPORT.md" | grep -q REPORT' \
  _ "$first" "$P1" "$inodes" "$(state p1 freed_bytes_run) $(state p1 freed_bytes_total) $(state p1 total_bytes)"

# ---- races (test hook: a command run just before each replace / rename; the target path is in AGENT_INPUTS_TEST_TARGET)
fresh; mkf "$P1/data/a.bin" "" "5 days ago"; dup "$P1/data/a.bin" "$P1/data2/a.bin"
conf "[p1]" data data2
AGENT_INPUTS_TEST_HOOK='before-replace:printf x >> "$AGENT_INPUTS_TEST_TARGET"' scan
check "changed during scan is skipped" bash -c '
  [ "$(stat -c %i "$1")" != "$(stat -c %i "$2")" ] && [ "$(stat -c %s "$2")" = 2097153 ] && [ "$(stat -c %h "$2")" = 1 ] &&
  [ -z "$(find "$3" -name ".agent-inputs-tmp-*")" ] && section Skipped "$3/data/REPORT.md" | grep -q "/workspace/data2/a.bin.*changed"' _ "$P1/data/a.bin" "$P1/data2/a.bin" "$P1"

fresh; mkf "$P1/data/a.bin" "" "5 days ago"; dup "$P1/data/a.bin" "$P1/data2/a.bin"; mkf "$OUT/secret.bin"
sum="$(stat -c '%i %h %a %Y %X' "$OUT/secret.bin") $(nsum "$OUT/secret.bin")"
conf "[p1]" data data2
AGENT_INPUTS_TEST_HOOK="before-replace:rm -f \"\$AGENT_INPUTS_TEST_TARGET\" && ln -s '$OUT/secret.bin' \"\$AGENT_INPUTS_TEST_TARGET\"" scan
check "race: symlink swapped in before replace" bash -c '
  [ "$(stat -c "%i %h %a %Y %X" "$1") $(nsum "$1")" = "$2" ] && [ -L "$3" ] && [ "$(readlink "$3")" = "$1" ] &&
  stat -c %A "$4" | grep -q w' _ "$OUT/secret.bin" "$sum" "$P1/data2/a.bin" "$P1/data/a.bin"

fresh; mkf "$P1/data/a.bin" "" "5 days ago"; dup "$P1/data/a.bin" "$P1/data2/a.bin"
orig="$(ino "$P1/data2/a.bin")"
conf "[p1]" data data2
AGENT_INPUTS_TEST_HOOK='before-rename:exit' ai scan >/dev/null 2>&1 || true
mid="$(ino "$P1/data2/a.bin") $(find "$P1" -name '.agent-inputs-tmp-*' | wc -l)"
scan
check "interrupted link leaves the original intact" bash -c '
  [ "$1" = "$2 1" ] && [ -z "$(find "$3" -name ".agent-inputs-tmp-*")" ]' _ "$mid" "$orig" "$P1"

fresh; mkf "$P1/data/a.bin" "" "5 days ago"; dup "$P1/data/a.bin" "$P1/data2/a.bin"; mkf "$P2/dataB/x.bin"
conf "[p1]" "group = g1" data data2 "[p2]" "group = g2" dataB
AGENT_INPUTS_TEST_HOOK='before-rename:rm -f "$AGENT_INPUTS_TEST_TARGET" && mkdir "$AGENT_INPUTS_TEST_TARGET"' ai scan >/dev/null 2>&1 && rc=0 || rc=$?
check "race: target swapped for a directory just before the replace is skipped and the run completes" bash -c '
  [ "$1" = 0 ] && [ -d "$2/data2/a.bin" ] && [ -z "$(find "$2" -name ".agent-inputs-tmp-*")" ] &&
  section Skipped "$2/data/REPORT.md" | grep -q "/workspace/data2/a.bin.*changed" && [ -f "$3/dataB/REPORT.md" ]' _ "$rc" "$P1" "$P2"

fresh; mkf "$P1/data/a.bin" "" "5 days ago"; dup "$P1/data/a.bin" "$P1/data2/a.bin"
conf "[p1]" data data2
AGENT_INPUTS_TEST_HOOK='before-rename:printf new > "$AGENT_INPUTS_TEST_TARGET.w" && mv "$AGENT_INPUTS_TEST_TARGET.w" "$AGENT_INPUTS_TEST_TARGET"' scan
check "race: a file written and renamed over the target just before the replace survives" bash -c '
  [ "$(cat "$1/data2/a.bin")" = new ] && [ "$(stat -c %h "$1/data2/a.bin")" = 1 ] && [ -z "$(find "$1" -name ".agent-inputs-tmp-*")" ] &&
  section Skipped "$1/data/REPORT.md" | grep -q "/workspace/data2/a.bin.*changed"' _ "$P1"

fresh; mkf "$P1/data/a.bin" "" "5 days ago"; dup "$P1/data/a.bin" "$P1/data2/a.bin" "" "10 days ago"; ln "$P1/data/a.bin" "$OUT/a-outside.bin"
before="$(stat -c '%i %h %a %X %Y' "$P1/data/a.bin" "$P1/data2/a.bin")"
conf "[p1]" data data2
scan
check "a file also linked outside the listed folders is left alone and listed" bash -c '
  [ "$(stat -c "%i %h %a %X %Y" "$1/data/a.bin" "$1/data2/a.bin")" = "$2" ] &&
  section Skipped "$1/data/REPORT.md" | grep -q "/workspace/data/a.bin.*outside the listed folders"' _ "$P1" "$before"

fresh; mkf "$P1/data/a.bin"
deep="$P1/data$(printf '/d%.0s' $(seq 1500))"; mkdir -p "$deep"; mkf "$deep/f.bin"
conf "[p1]" data
ai scan >/dev/null 2>&1 && rc=0 || rc=$?
check "a 1500-deep folder tree is walked and still gets a report" bash -c '
  [ "$1" = 0 ] && section "Not read in" "$2/data/REPORT.md" | grep -q "/d/d/f.bin"' _ "$rc" "$P1"

# ---- round 2: names, open writers, permissions, cleanup, times, sizes, link counts, short writes
fresh; mkf "$P1/data/a.bin"; dup "$P1/data/a.bin" "$P1/data2/a.bin"
bad="$P1/data/x"$'\xff'; evil="$P1/data/evil"$'\n''## Skipped'$'\n''- fake'
: > "$bad"; settime "$bad"; : > "$evil"; settime "$evil"
conf "[p1]" data data2
ai scan >/dev/null 2>&1 && rc=0 || rc=$?
check "names with undecodable bytes or newlines are escaped in the report" bash -c '
  [ "$1" = 0 ] && [ "$(grep -c "^## Skipped" "$2/data/REPORT.md")" = 1 ] && ! grep -q "^- fake" "$2/data/REPORT.md" &&
  grep -qF "x\\xff" "$2/data/REPORT.md" && grep -qF "evil\\x0a## Skipped\\x0a- fake" "$2/data/REPORT.md" &&
  [ "$(stat -c %i "$2/data/a.bin")" = "$(stat -c %i "$2/data2/a.bin")" ]' _ "$rc" "$P1"

writer_case(){ # $1 which path holds a writer (data = kept, data2 = duplicate)
  fresh; mkf "$P1/data/a.bin" "" "5 days ago"; dup "$P1/data/a.bin" "$P1/data2/a.bin"
  orig="$(ino "$P1/data2/a.bin")"; conf "[p1]" data data2
  sleep 600 >> "$P1/$1/a.bin" & w=$!
  scan
  kill "$w"; wait "$w" 2>/dev/null || true
}
writer_case data2
check "a duplicate open for writing is not linked" bash -c '
  [ "$(stat -c %i "$1/data2/a.bin")" = "$2" ] && section Skipped "$1/data/REPORT.md" | grep -q "/workspace/data2/a.bin.*open for writing"' _ "$P1" "$orig"
writer_case data
check "a kept file open for writing gets no links and stays writable" bash -c '
  [ "$(stat -c %i "$1/data2/a.bin")" = "$2" ] && stat -c %A "$1/data/a.bin" | grep -q w &&
  section Skipped "$1/data/REPORT.md" | grep -q "/workspace/data2/a.bin.*open for writing"' _ "$P1" "$orig"

fresh; mkf "$P1/data/a.bin" "" "5 days ago"; dup "$P1/data/a.bin" "$P1/data2/a.bin"; chmod 755 "$P1/data2/a.bin"
orig="$(ino "$P1/data2/a.bin")"; conf "[p1]" data data2
scan
check "a duplicate with different permissions is not linked" bash -c '
  [ "$(stat -c "%i %a" "$1/data2/a.bin")" = "$2 755" ] && section Skipped "$1/data/REPORT.md" | grep -q "/workspace/data2/a.bin.*different permissions or group"' _ "$P1" "$orig"

fresh; mkf "$P1/data/a.bin" "" "5 days ago"; dup "$P1/data/a.bin" "$P1/data2/a.bin"
if python3 -c 'import os,sys; os.setxattr(sys.argv[1], "user.t", b"1")' "$P1/data2/a.bin" 2>/dev/null; then
  orig="$(ino "$P1/data2/a.bin")"; conf "[p1]" data data2
  scan
  check "a duplicate with extended attributes is not linked" bash -c '
    [ "$(stat -c %i "$1/data2/a.bin")" = "$2" ] && section Skipped "$1/data/REPORT.md" | grep -q "/workspace/data2/a.bin.*extended attributes"' _ "$P1" "$orig"
else
  echo "SKIP: a duplicate with extended attributes is not linked (no user xattrs on this filesystem)"
fi

fresh; mkf "$P1/data/a.bin" "" "5 days ago"; dup "$P1/data/a.bin" "$P1/data2/a.bin"; conf "[p1]" data data2
AGENT_INPUTS_TEST_HOOK='after-exchange:printf new > "$AGENT_INPUTS_TEST_TMP.w" && mv "$AGENT_INPUTS_TEST_TMP.w" "$AGENT_INPUTS_TEST_TMP" && rm "$AGENT_INPUTS_TEST_TARGET"' \
  ai scan >/dev/null 2>&1 && rc=0 || rc=$?
check "a failed swap-back keeps the other file, exits 1 and asks for the owner's attention" bash -c '
  t="$(find "$2/data2" -name ".agent-inputs-tmp-*")"; [ "$1" = 1 ] && [ -n "$t" ] && [ "$(cat "$t")" = new ] &&
  section "attention" "$2/data/REPORT.md" | grep -q "/workspace/data2/$(basename "$t")"' _ "$rc" "$P1"

fresh; mkf "$P1/data/a.bin" "" "5 days ago"; dup "$P1/data/a.bin" "$P1/data2/a.bin"; conf "[p1]" data data2
AGENT_INPUTS_TEST_HOOK='before-cleanup:printf new > "$AGENT_INPUTS_TEST_TMP.w" && mv "$AGENT_INPUTS_TEST_TMP.w" "$AGENT_INPUTS_TEST_TMP"' \
  ai scan >/dev/null 2>&1 && rc=0 || rc=$?
check "cleanup removes a temp name only if it is the expected file, and credits no space otherwise" bash -c '
  t="$(find "$2/data2" -name ".agent-inputs-tmp-*")"; [ "$1" = 1 ] && [ -n "$t" ] && [ "$(cat "$t")" = new ] && [ "$3" = 0 ] &&
  section "attention" "$2/data/REPORT.md" | grep -q "/workspace/data2/$(basename "$t")"' _ "$rc" "$P1" "$(state p1 freed_bytes_run)"

fresh; mkf "$P1/data/a.bin" "" "5 days ago"; dup "$P1/data/a.bin" "$P1/data2/a.bin"; conf "[p1]" data data2
# after the exchange, a writer opens the duplicate (now at the temp name) for append and blocks on the
# job's read lease; the hook returns once the kernel shows that lease breaking
AGENT_INPUTS_TEST_HOOK='after-exchange:( printf data >> "$AGENT_INPUTS_TEST_TMP" ) & for i in $(seq 200); do grep -q BREAKING /proc/locks && break; sleep 0.05; done' scan
for i in $(seq 100); do [ "$(stat -c %s "$P1/data2/a.bin")" = 2097156 ] && break; sleep 0.05; done
check "a duplicate opened for writing during the exchange is swapped back and keeps the writer's data" bash -c '
  [ "$(stat -c %s "$1/data2/a.bin")" = 2097156 ] && [ "$(tail -c 4 "$1/data2/a.bin")" = data ] &&
  [ "$(stat -c %i "$1/data/a.bin")" != "$(stat -c %i "$1/data2/a.bin")" ] && [ -z "$(find "$1" -name ".agent-inputs-tmp-*")" ] &&
  section Skipped "$1/data/REPORT.md" | grep -q "/workspace/data2/a.bin.*opened for writing during the scan"' _ "$P1"

fresh; mkf "$P1/data/a.bin" "" "5 days ago"; dup "$P1/data/a.bin" "$P1/data2/a.bin"; conf "[p1]" data data2
AGENT_INPUTS_TEST_HOOK='before-replace:cat "$AGENT_INPUTS_TEST_TARGET" > /dev/null' scan
check "a read during the scan is kept in the linked file's last-read time" bash -c '
  [ "$(stat -c %i "$1/data/a.bin")" = "$(stat -c %i "$1/data2/a.bin")" ] && [ "$(stat -c %X "$1/data/a.bin")" -gt "$(( $(date +%s) - 3600 ))" ]' _ "$P1"

fresh; mkdir -p "$P1/data" "$P1/data2"; truncate -s 2M "$P1/data/z.bin"; settime "$P1/data/z.bin" "" "5 days ago"
cp --sparse=always "$P1/data/z.bin" "$P1/data2/z.bin"; settime "$P1/data2/z.bin"; conf "[p1]" data data2
scan
check "freed and total sizes count allocated blocks (sparse files)" bash -c '
  [ "$(stat -c %i "$1/data/z.bin")" = "$(stat -c %i "$1/data2/z.bin")" ] && [ "$2" = "$(( $(stat -c %b "$1/data/z.bin") * 512 ))" ] &&
  [ "$3" -lt 1048576 ]' _ "$P1" "$(state p1 freed_bytes_run)" "$(state p1 total_bytes)"

fresh; mkf "$P1/data/a.bin" "" "5 days ago"; dup "$P1/data/a.bin" "$P1/data2/a.bin"; orig="$(ino "$P1/data2/a.bin")"; conf "[p1]" data data2
AGENT_INPUTS_TEST_HOOK="before-replace:ln '$P1/data/a.bin' '$OUT/alias.bin'" scan
check "a new outside link to the kept file during the scan stops linking" bash -c '
  [ "$(stat -c %i "$1/data2/a.bin")" = "$2" ] && stat -c %A "$3" | grep -q w &&
  section Skipped "$1/data/REPORT.md" | grep -q "/workspace/data2/a.bin.*link count changed"' _ "$P1" "$orig" "$OUT/alias.bin"

fresh; mkf "$P1/data/a.bin" "" "5 days ago"; dup "$P1/data/a.bin" "$P1/data2/a.bin"; orig="$(ino "$P1/data2/a.bin")"; conf "[p1]" data data2
AGENT_INPUTS_TEST_HOOK="before-replace:ln \"\$AGENT_INPUTS_TEST_TARGET\" '$OUT/talias.bin'" scan
check "a new outside link to the duplicate during the scan stops linking" bash -c '
  [ "$(stat -c %i "$1/data2/a.bin")" = "$2" ] && section Skipped "$1/data/REPORT.md" | grep -q "/workspace/data2/a.bin.*link count changed"' _ "$P1" "$orig"

fresh; mkdir -p "$P1/data"
for i in $(seq 40); do f="$P1/data/a-file-with-a-rather-long-name-to-make-the-report-big-$i.txt"; : > "$f"; settime "$f"; done
conf "[p1]" data
( ulimit -f 2; ai scan >/dev/null 2>&1 ) && rc=0 || rc=$?
check "a report that cannot be written in full is not published" bash -c '
  [ "$1" != 0 ] && [ ! -e "$2/data/REPORT.md" ] && [ ! -e "$2/data/REPORT.md.tmp" ]' _ "$rc" "$P1"

# ---- config refusals (exit 2, the message names inputs.conf and the line)
fresh; mkdir -p "$P1/data" "$P1/research-dl"
conf "[research]" data; refuses "config refusals: research section" "inputs.conf line 1:.*research" scan2
conf "# comment" "[nope]" data; refuses "config refusals: unknown section" "inputs.conf line 2:.*nope" scan2
conf "[p1]" data missing; refuses "config refusals: missing folder" "inputs.conf line 3:.*does not exist" scan2
conf "[p1]" data "data/../data"; refuses "config refusals: folder with .." "inputs.conf line 3:.*\.\." scan2
conf "[p1]" "$P1/data"; refuses "config refusals: absolute folder" "inputs.conf line 2:.*absolute" scan2
conf "[p1]" data research-dl; refuses "config refusals: folder overlapping RESEARCH_DIR" "inputs.conf line 3:.*RESEARCH_DIR" scan2
mkdir -p "$CFG/p4" "$P1/sub"; printf 'PROJECT=p4\nPROFILE=builder\nPROJECT_DIR=%s\n' "$P1/sub" > "$CFG/p4/project.conf"
conf "[p1]" data; refuses "config refusals: PROJECT_DIR inside another builder's PROJECT_DIR" "inputs.conf line 1:.*p4" scan2
rm -rf "$CFG/p4"
mkdir -p "$CFG/p5" "$H/GitHub/real5/data"; ln -s "$H/GitHub/real5" "$H/GitHub/p5"
printf 'PROJECT=p5\nPROFILE=builder\nPROJECT_DIR=%s\n' "$H/GitHub/p5" > "$CFG/p5/project.conf"
conf "[p5]" data; refuses "config refusals: PROJECT_DIR that is a symlink" "inputs.conf line 1:.*symlink" scan2
rm -rf "$CFG/p5"
if [ -d /dev/shm ] && [ "$(stat -c %d /dev/shm)" != "$(stat -c %d "$T")" ]; then
  SHM="$(mktemp -d /dev/shm/agent-inputs-test.XXXXXX)"; mkdir -p "$SHM/p3/data" "$CFG/p3"
  printf 'PROJECT=p3\nPROFILE=builder\nPROJECT_DIR=%s\n' "$SHM/p3" > "$CFG/p3/project.conf"
  conf "[p1]" "group = g" data "[p3]" "group = g" data
  refuses "config refusals: folder on another filesystem" "inputs.conf line 6:.*filesystem" scan2
  rm -rf "$CFG/p3"
else
  echo "SKIP: config refusals: folder on another filesystem (no second filesystem at /dev/shm)"
fi

# ---- skipped files and the published report
fresh; mkf "$P1/data/a.bin"; dup "$P1/data/a.bin" "$P1/data2/a.bin"; chmod 000 "$P1/data2/a.bin"
orig="$(ino "$P1/data2/a.bin")"
conf "[p1]" data data2
scan
check "unreadable file is skipped and listed with its reason" bash -c '
  [ "$(stat -c %i "$1")" = "$2" ] && [ "$(stat -c %h "$1")" = 1 ] && section Skipped "$3" | grep -Eq "/workspace/data2/a.bin.*(denied|unreadable)"' _ "$P1/data2/a.bin" "$orig" "$P1/data/REPORT.md"
chmod 644 "$P1/data2/a.bin"

fresh; mkf "$P1/data/a.bin"; dup "$P1/data/a.bin" "$P1/data2/a.bin"; mkf "$P1/data/u.bin"; chmod 000 "$P1/data/u.bin"
conf "[p1]" data data2
scan
check "report has no host home path" bash -c '[ -s "$1" ] && ! grep -F "$2" "$1" && ! grep -F "$3" "$1"' _ "$P1/data/REPORT.md" "$H" "$T"
chmod 644 "$P1/data/u.bin"

fresh; mkf "$P1/data/a.bin"; printf 'keep\n' > "$OUT/victim.txt"; ln -s "$OUT/victim.txt" "$P1/data/REPORT.md"
printf 'keep\n' > "$OUT/victim2.txt"; ln -s "$OUT/victim2.txt" "$P1/data/REPORT.md.tmp"
conf "[p1]" data
scan
check "report published through a symlinked REPORT.md does not write outside" bash -c '
  [ "$(cat "$1")" = keep ] && [ "$(cat "$2")" = keep ] && [ ! -L "$3" ] && [ -f "$3" ] && grep -q "^# " "$3"' _ "$OUT/victim.txt" "$OUT/victim2.txt" "$P1/data/REPORT.md"

[ "$fail" -eq 0 ] && echo "AGENT-INPUTS: ALL PASSED" || { echo "AGENT-INPUTS: FAILURES"; exit 1; }
