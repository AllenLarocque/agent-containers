#!/usr/bin/env bash
# Paper-tool checks. Run by scripts/build-publish.sh with --network none (spec §6.1): nothing may reach out.
set -euo pipefail
fail=0
exec 3>&1   # the real stdout: INFO lines from inside a check (whose output is captured) go here
# On failure, print the command, its exit code and the last 40 lines of its output (stdout+stderr).
check(){
  local d="$1"; shift; local out rc=0
  out=$("$@" 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then echo "OK:   $d"; else
    echo "FAIL: $d (exit $rc): $*"; printf '%s\n' "$out" | tail -n 40 | sed 's/^/    | /'; fail=1
  fi
}
# --- PDF tools, offline, on a real paper (fixture: Eddelbuettel & Francois 2011, JSS 40(8)) ---
S=/tests/fixtures/pdf/rcpp-jss-2011.pdf
w=$(mktemp -d)   # scratch; scan.pdf and scan-ocr.pdf stay here for the later GROBID checks
M=/opt/paper-tools/MANIFEST

manifest_exact() {
  local apt pip
  apt=$(awk '/^apt:/{print $2}' "$M" | paste -sd' ')
  pip=$(grep '^pip:' "$M" | paste -sd'|')
  [ "$apt" = "poppler-utils qpdf tesseract-ocr tesseract-ocr-eng tesseract-ocr-osd openjdk-21-jre-headless" ] \
    || { echo "apt names: $apt"; return 1; }
  [ "$pip" = "pip: ocrmypdf==17.13.0|pip: paper-search-mcp @ git+https://github.com/openags/paper-search-mcp@cab1b5cc276a0cd004a0044003926a6440088049" ] \
    || { echo "pip lines: $pip"; return 1; }
}
no_network() { ! curl -sS -m 5 -o /dev/null https://pypi.org; }
no_gs() { ! command -v gs; }
ocrmypdf_venv() {
  [[ $(ocrmypdf --version) == 17.13.0* ]] || { echo "ocrmypdf: $(ocrmypdf --version)"; return 1; }
  [[ $(/opt/paper-tools/venv/bin/python -V) == "Python 3.12"* ]]
}
pages_ok() { local n; n=$(pdfinfo "$S" | awk '/^Pages:/{print $2}'); echo "pages: $n"; [ "${n:-0}" -ge 10 ]; }
text_ok() { local t; t=$(pdftotext -layout "$S" -) || return 1; [[ $t == *'Seamless R and C++ Integration'* ]]; }  # no `| grep -q`: SIGPIPE + pipefail
qpdf_repairs() {
  # The fixture ends in an xref stream, which qpdf cannot recover once cut, so first rewrite it with a
  # classic xref table, then cut at the last startxref (startxref, offset and %%EOF lost, as in a truncated download).
  local rc=0 off t
  qpdf --object-streams=disable "$S" "$w/plain.pdf" || return 1
  off=$(grep -abo startxref "$w/plain.pdf" | tail -n1 | cut -d: -f1)
  [[ $off =~ ^[0-9]+$ ]] && [ "$off" -gt 0 ] || { echo "no startxref offset: '$off'"; return 1; }
  head -c "$off" "$w/plain.pdf" > "$w/broken.pdf" || return 1
  qpdf "$w/broken.pdf" "$w/fixed.pdf" || rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 3 ] || { echo "qpdf exit $rc"; return 1; }
  t=$(pdftotext "$w/fixed.pdf" -) || return 1
  [[ $t == *Seamless* ]]
}
ocr_scanned_page() {
  pdftoppm -r 200 -f 1 -l 1 -png -singlefile "$S" "$w/p" || return 1   # no set -e inside check: every step must return
  /opt/paper-tools/venv/bin/img2pdf "$w/p.png" -o "$w/scan.pdf" || return 1
  local n
  n=$(pdftotext "$w/scan.pdf" - | tr -d '[:space:]' | wc -c)
  echo "text chars in the image-only PDF: $n"
  [ "$n" -lt 20 ] || return 1
  # Peak RSS of ocrmypdf and its children (tesseract), INFO only: printed to the log via fd 3.
  local info rc=0
  info=$(/opt/paper-tools/venv/bin/python -I -c '
import resource, subprocess, sys
r = subprocess.run(sys.argv[1:], stdout=sys.stderr)
print("INFO: ocrmypdf peak RSS: %d KiB" % resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss)
sys.exit(r.returncode)' ocrmypdf --output-type pdf --sidecar "$w/scan.txt" "$w/scan.pdf" "$w/scan-ocr.pdf") || rc=$?
  printf '%s\n' "$info" >&3
  [ "$rc" -eq 0 ] || return 1
  grep -qi seamless "$w/scan.txt"
}

# --- GROBID (CRF only) through the `grobid` wrapper, on 127.0.0.1:8070 ---
Y=/opt/paper-tools/grobid/grobid-home/config/grobid.yaml
grobid_installed() {
  grep -Eq '^grobid: grobid/grobid:0\.9\.1-crf@sha256:[0-9a-f]{64} ' "$M" || { echo "MANIFEST:"; cat "$M"; return 1; }
  grep -Eq '^[[:space:]]+concurrency: 2[[:space:]]*$' "$Y" || { grep -n concurrency "$Y"; return 1; }
  grep -Eq '^[[:space:]]+memoryLimitMb: 2048[[:space:]]*$' "$Y" || { grep -n memoryLimitMb "$Y"; return 1; }
  local v; v=$(java -version 2>&1) || return 1
  echo "$v"; [[ $v == *'version "21'* ]]
}
java_count() { local n; n=$(pgrep -cx java) || true; echo "${n:-0}"; }
start_idempotent() {
  local n pid i
  grobid start || return 1
  grobid start || return 1
  n=$(java_count); [ "$n" -eq 1 ] || { echo "java processes after two starts: $n"; ps -eo pid,stat,args; return 1; }
  pid=$(pgrep -x java) || return 1
  kill -9 "$pid" || return 1   # a crash: the pidfile is now stale
  for ((i = 0; i < 20; i++)); do [ -e "/proc/$pid" ] || break; sleep 0.5; done
  grobid start || return 1
  n=$(java_count); [ "$n" -eq 1 ] || { echo "java processes after crash + start: $n"; ps -eo pid,stat,args; return 1; }
}
loopback_only() {  # every socket listening on 8070/8071 is bound to 127.0.0.1
  local l addr seen=0 bad=0
  l=$(ss -Hltn) || return 1
  printf '%s\n' "$l"
  while read -r _ _ _ addr _; do
    case $addr in
      *:8070|*:8071)
        case $addr in *:8070) seen=1 ;; esac
        case $addr in 127.0.0.1:*|'[::ffff:127.0.0.1]:'*) ;; *) bad=1 ;; esac ;;
    esac
  done <<< "$l"
  [ "$seen" -eq 1 ] && [ "$bad" -eq 0 ]
}
tei_ok() {  # tei_ok <tei> <word>: the teiHeader's main title contains <word> (reference titles use the same element)
  local h t
  [ -s "$1" ] || { echo "no TEI at $1"; return 1; }
  h=$(sed -n '1,/<\/teiHeader>/p' "$1")
  t=$(grep -m1 -o '<title level="a" type="main"[^>]*>[^<]*' <<< "$h") || { echo "no main title in the teiHeader"; return 1; }
  echo "title: $t"
  [[ $t == *"$2"* ]]
}
grobid_fulltext() {
  local b h
  grobid fulltext "$S" "$w/a.tei.xml" || return 1
  tei_ok "$w/a.tei.xml" Rcpp || return 1
  local refs; refs=$(sed -n '/<listBibl/,$p' "$w/a.tei.xml")   # references only, not the header's sourceDesc biblStruct
  b=$(grep -o '<biblStruct' <<< "$refs" | wc -l)
  h=$(grep -oE '<head[ >]' "$w/a.tei.xml" | wc -l)
  echo "biblStruct: $b, head: $h"
  [ "$b" -ge 10 ] && [ "$h" -ge 3 ]
}
grobid_header() {
  grobid header "$S" "$w/h.tei.xml" || return 1
  tei_ok "$w/h.tei.xml" Rcpp
}
grobid_three_at_once() {  # concurrency is 2, so one run meets HTTP 503 and must retry, not fail
  local i rc ok=0 pids=()
  for i in 1 2 3; do grobid fulltext "$S" "$w/c$i.tei.xml" & pids+=("$!"); done
  for i in 1 2 3; do
    rc=0; wait "${pids[$((i - 1))]}" || rc=$?
    echo "run $i: exit $rc"
    [ "$rc" -eq 0 ] || ok=1
  done
  [ "$ok" -eq 0 ] || return 1
  for i in 1 2 3; do tei_ok "$w/c$i.tei.xml" Rcpp || return 1; done
}
grobid_hostile_name() {
  cp "$S" "$w/A paper; v2, final.pdf" || return 1
  grobid fulltext "$w/A paper; v2, final.pdf" "$w/A paper; v2, final.tei.xml" || return 1
  tei_ok "$w/A paper; v2, final.tei.xml" Rcpp
}
grobid_image_only() {  # exit 2 with the ocrmypdf hint on stderr, and no output file (nor temp file) left
  local rc=0 err left
  err=$(grobid fulltext "$w/scan.pdf" "$w/s.tei.xml" 2>&1 >/dev/null) || rc=$?
  echo "exit $rc; stderr: $err"
  [ "$rc" -eq 2 ] || return 1
  [[ $err == *ocrmypdf* ]] || return 1
  [ ! -e "$w/s.tei.xml" ] || { echo "s.tei.xml was created"; return 1; }
  left=$(compgen -G "$w/s.tei.xml.*") && { echo "temp file left: $left"; return 1; }
  return 0
}
grobid_after_ocr() {
  grobid fulltext "$w/scan-ocr.pdf" "$w/so.tei.xml" || return 1
  # This tests the pipeline, not Tesseract's accuracy: at 200 dpi it reads "Rcpp" as "Rcepp", so check the plain words.
  tei_ok "$w/so.tei.xml" Seamless && tei_ok "$w/so.tei.xml" Integration
}
info_jvm_rss() {  # INFO only, no threshold
  local pid hwm
  pid=$(pgrep -x java) || { echo "INFO: grobid JVM peak RSS: (no JVM running)"; return 0; }
  hwm=$(awk '/^VmHWM:/{print $2, $3}' "/proc/$pid/status")
  echo "INFO: grobid JVM peak RSS: $hwm"
}
grobid_stop() {
  local rc=0
  grobid stop || return 1
  grobid status || rc=$?
  [ "$rc" -eq 1 ] || { echo "grobid status after stop: exit $rc"; return 1; }
}

# --- paper-search-mcp: installed, registered for Claude in the research profile only, Sci-Hub tools denied ---
PSM=/opt/paper-tools/venv/bin/paper-search-mcp
pc=$(mktemp -d)   # fake profile files and Claude config dirs (the real /etc/firewall/profile is root's)
printf 'PROFILE=research\n' > "$pc/research"; printf 'PROFILE=builder\n' > "$pc/builder"
configure() {  # configure <profile file> <claude config dir>: what agent-init runs at container start
  AGENT_PROFILE_FILE="$1" CLAUDE_CONFIG_DIR="$2" node /usr/local/lib/agent/configure-claude-settings.js "$(command -v node)"
}
registered() { jq -e '.mcpServers["paper-search"] != null' "$1/.claude.json" >/dev/null 2>&1; }
# Start the server exactly as registered in <claude config dir>/.claude.json, over stdio, and print the
# tool definitions it serves (what Claude sees) as JSON. The server's stderr goes to <errlog>.
list_tools() {  # list_tools <claude config dir> <errlog>
  /opt/paper-tools/venv/bin/python -I -c '
import asyncio, json, os, sys
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
cfg = json.load(open(sys.argv[1]))["mcpServers"]["paper-search"]
async def main():
    p = StdioServerParameters(command=cfg["command"], args=cfg.get("args", []), env=dict(os.environ, **cfg.get("env", {})))
    with open(sys.argv[2], "w") as err:
        async with stdio_client(p, errlog=err) as (r, w):
            async with ClientSession(r, w) as s:
                await s.initialize()
                print(json.dumps([t.model_dump(mode="json") for t in (await s.list_tools()).tools]))
asyncio.run(asyncio.wait_for(main(), 90))' "$1/.claude.json" "$2"
}
paper_search_installed() {
  [ -x "$PSM" ] || { echo "no $PSM"; return 1; }
  [ "$(readlink /usr/local/bin/paper-search-mcp)" = "$PSM" ] || { echo "/usr/local/bin/paper-search-mcp is not a link to $PSM"; return 1; }
  /opt/paper-tools/venv/bin/python -I -c 'import paper_search_mcp.server'
}
paper_search_registered_research() {  # the registered server starts offline and serves its tools
  local n
  configure "$pc/research" "$pc/r" || return 1
  registered "$pc/r" || { echo "no paper-search in $pc/r/.claude.json"; return 1; }
  list_tools "$pc/r" "$pc/r.err" > "$pc/tools.json" || { tail -n 20 "$pc/r.err"; return 1; }
  n=$(jq length "$pc/tools.json"); echo "tools: $n"
  [ "$n" -ge 30 ] && jq -e 'map(.name) | index("search_arxiv") and index("download_arxiv")' "$pc/tools.json" >/dev/null
}
# Keyed on behaviour, not on one name (Review Focus 1): EVERY served tool whose definition (name,
# description or parameters) mentions Sci-Hub must be denied to Claude by name.
scihub_tools_denied() {
  local t found=0
  while IFS= read -r t; do
    found=1; echo "Sci-Hub tool: $t"
    jq -e --arg r "mcp__paper-search__$t" '.permissions.deny // [] | index($r)' "$pc/r/settings.json" >/dev/null \
      || { echo "NOT denied: mcp__paper-search__$t"; return 1; }
  done < <(jq -r '.[] | select(tostring | test("sci.?hub"; "i")) | .name' "$pc/tools.json")
  # None found means the enumeration broke, or upstream dropped Sci-Hub (then update this check).
  [ "$found" -eq 1 ]
}
scihub_not_enabled() {  # nothing switches Sci-Hub on: not the environment, the registration or an allow rule
  if grep -Eiq 'sci.?hub' <<< "$(env)"; then echo "environment mentions Sci-Hub"; return 1; fi
  if grep -Eiq 'sci.?hub' <<< "$(jq -c '.mcpServers["paper-search"]' "$pc/r/.claude.json")"; then echo "registration mentions Sci-Hub"; return 1; fi
  jq -e '.permissions.allow // [] | map(select(test("sci.?hub|paper-search"; "i"))) | length == 0' "$pc/r/settings.json" >/dev/null \
    || { echo "an allow rule names the server or Sci-Hub"; return 1; }
}
contact_email_passed() {  # Unpaywall gets RESEARCH_CONTACT_EMAIL when set; unset, the server still starts (Review Focus 2)
  grep -q UNPAYWALL "$pc/r.err" || { echo "unset: no Unpaywall warning on stderr"; return 1; }
  RESEARCH_CONTACT_EMAIL=papers+research@relay.example list_tools "$pc/r" "$pc/e.err" >/dev/null || { tail -n 20 "$pc/e.err"; return 1; }
  if grep -q UNPAYWALL "$pc/e.err"; then echo "set: the server still says the Unpaywall email is missing"; return 1; fi
}
paper_search_not_builder() {  # no profile file, PROFILE=builder, and research -> builder on the same volume
  configure "$pc/absent" "$pc/b1" || return 1
  configure "$pc/builder" "$pc/b2" || return 1
  configure "$pc/research" "$pc/b3" && configure "$pc/builder" "$pc/b3" || return 1
  local d; for d in b1 b2 b3; do if registered "$pc/$d"; then echo "registered in $d"; return 1; fi; done
}
broken_claude_json_kept() {  # a registration failure warns, keeps the file, and still writes the settings (Review Focus 4)
  mkdir -p "$pc/x" && printf '{not json\n' > "$pc/x/.claude.json" && cp "$pc/x/.claude.json" "$pc/x/before"
  configure "$pc/research" "$pc/x" || return 1
  cmp "$pc/x/before" "$pc/x/.claude.json" && jq -e '.permissions.defaultMode == "bypassPermissions"' "$pc/x/settings.json" >/dev/null
}

check "MANIFEST lists exactly the specs"            manifest_exact
check "no Ghostscript"                              no_gs
check "ocrmypdf on PATH, venv python 3.12"          ocrmypdf_venv
check "pdfinfo: at least 10 pages"                  pages_ok
check "pdftotext finds the title"                   text_ok
check "network is off"                              no_network
check "pdfimages -list"                             pdfimages -list "$S"
check "qpdf --check"                                qpdf --check "$S"
check "qpdf rebuilds a copy with its xref tail cut off"         qpdf_repairs
check "OCR of a scanned page"                       ocr_scanned_page
check "grobid installed"                            grobid_installed
check "grobid start is idempotent (also after a crash)"  start_idempotent
check "grobid listens on 127.0.0.1 only"            loopback_only
check "grobid fulltext"                             grobid_fulltext
check "grobid on a hostile file name"               grobid_hostile_name
check "grobid on image-only PDF"                    grobid_image_only
check "scan -> OCR -> GROBID"                       grobid_after_ocr
check "grobid header"                               grobid_header
check "three grobid fulltext runs at once"          grobid_three_at_once
info_jvm_rss || true
check "grobid stop"                                 grobid_stop
check "paper-search-mcp installed (import + entry point)"           paper_search_installed
check "paper-search registered for research, starts offline"        paper_search_registered_research
check "every tool that mentions Sci-Hub is denied"                  scihub_tools_denied
check "nothing enables Sci-Hub"                                     scihub_not_enabled
check "RESEARCH_CONTACT_EMAIL reaches Unpaywall; unset still starts" contact_email_passed
check "paper-search NOT registered for builders"                    paper_search_not_builder
check "unreadable .claude.json: kept, settings still written"       broken_claude_json_kept
[ "$fail" -eq 0 ] && echo "SMOKE research-offline: ALL PASSED" || { echo "SMOKE research-offline: FAILURES"; exit 1; }
