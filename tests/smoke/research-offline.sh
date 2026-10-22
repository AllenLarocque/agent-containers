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
  [ "$pip" = "pip: ocrmypdf==17.13.0" ] || { echo "pip lines: $pip"; return 1; }
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
tei_ok() {  # tei_ok <tei> <word>: the header's main title (the first one; reference titles use the same element) contains <word>
  local t
  [ -s "$1" ] || { echo "no TEI at $1"; return 1; }
  t=$(grep -m1 -o '<title level="a" type="main"[^>]*>[^<]*' "$1") || { echo "no main title"; return 1; }
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
info_jvm_rss || true
check "grobid stop"                                 grobid_stop
[ "$fail" -eq 0 ] && echo "SMOKE research-offline: ALL PASSED" || { echo "SMOKE research-offline: FAILURES"; exit 1; }
