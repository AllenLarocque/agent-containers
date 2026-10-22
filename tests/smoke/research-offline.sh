#!/usr/bin/env bash
# Paper-tool checks. Run by scripts/build-publish.sh with --network none (spec §6.1): nothing may reach out.
set -euo pipefail
fail=0
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
  ocrmypdf --output-type pdf --sidecar "$w/scan.txt" "$w/scan.pdf" "$w/scan-ocr.pdf" || return 1
  grep -qi seamless "$w/scan.txt"
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
[ "$fail" -eq 0 ] && echo "SMOKE research-offline: ALL PASSED" || { echo "SMOKE research-offline: FAILURES"; exit 1; }
