#!/usr/bin/env bash
# Install the PDF tools listed in <dir>/apt.txt and <dir>/python.txt (one package spec per line;
# '#' comments and blank lines ignored).
#   apt lines    -> apt-get install --no-install-recommends
#   python lines -> pip install into the venv /opt/paper-tools/venv (created only if there are entries)
# Writes /opt/paper-tools/MANIFEST: one line per installed spec (empty file when there are none).
# Usage: install.sh <dir>
set -euo pipefail
dir=${1:?directory holding apt.txt and python.txt}
out=/opt/paper-tools

specs() {  # print the spec lines of a list file: comments and blank lines dropped, whitespace trimmed
  local line
  [ -f "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -z "$line" ] || printf '%s\n' "$line"
  done < "$1"
}

apt_pkgs=(); py_pkgs=()
while IFS= read -r l; do apt_pkgs+=("$l"); done < <(specs "$dir/apt.txt")
while IFS= read -r l; do py_pkgs+=("$l"); done < <(specs "$dir/python.txt")

mkdir -p "$out"
: > "$out/MANIFEST"

if [ "${#apt_pkgs[@]}" -gt 0 ]; then
  apt-get update
  apt-get install -y --no-install-recommends "${apt_pkgs[@]}"
  apt-get clean && rm -rf /var/lib/apt/lists/*
  printf 'apt: %s\n' "${apt_pkgs[@]}" >> "$out/MANIFEST"
fi

if [ "${#py_pkgs[@]}" -gt 0 ]; then
  python3 -m venv "$out/venv"
  "$out/venv/bin/pip" install --no-cache-dir "${py_pkgs[@]}"
  printf 'pip: %s\n' "${py_pkgs[@]}" >> "$out/MANIFEST"
fi

chmod -R a+rX "$out"
echo "paper tools: ${#apt_pkgs[@]} apt, ${#py_pkgs[@]} python"
