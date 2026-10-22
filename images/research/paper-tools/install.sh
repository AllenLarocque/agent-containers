#!/usr/bin/env bash
# Install the PDF tools listed in <dir>/apt.txt and <dir>/python.txt (one package spec per line;
# blank lines ignored). A comment starts at '#' at the start of a line or after whitespace, so
# `name==1.0  # why` works and `pkg @ https://host/f.whl#sha256=...` keeps its fragment.
#   apt lines    -> apt-get install --no-install-recommends
#   python lines -> uv pip install into the venv /opt/paper-tools/venv (created only if there are
#                   entries; built on /usr/bin/python3 with uv, which needs no ensurepip)
# Writes /opt/paper-tools/MANIFEST: "apt: <pkg> <installed version>" / "pip: <spec>" per spec (empty
# file when there are none), /opt/paper-tools/python.freeze (the full resolved set), and links each
# python spec's console script of the same name into /usr/local/bin.
# Usage: install.sh <dir>
set -euo pipefail
dir=${1:?directory holding apt.txt and python.txt}
out=/opt/paper-tools

specs() {  # print the spec lines of a list file: comments and blank lines dropped, whitespace trimmed
  [ -f "$1" ] || return 0
  sed -E 's/(^|[[:space:]])#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//; /^$/d' "$1"
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
  for p in "${apt_pkgs[@]}"; do
    printf 'apt: %s %s\n' "$p" "$(dpkg-query -W -f='${Version}' "$p")" >> "$out/MANIFEST"
  done
fi

if [ "${#py_pkgs[@]}" -gt 0 ]; then
  export UV_PYTHON_DOWNLOADS=never  # only the distro /usr/bin/python3, never a downloaded interpreter
  uv venv --python /usr/bin/python3 "$out/venv"
  UV_NO_CACHE=1 uv pip install --python "$out/venv/bin/python" "${py_pkgs[@]}"
  uv pip freeze --python "$out/venv/bin/python" > "$out/python.freeze"
  for p in "${py_pkgs[@]}"; do
    printf 'pip: %s\n' "$p" >> "$out/MANIFEST"
    name=$(printf '%s' "$p" | sed -E 's/[]=<>!~[ @;].*$//')  # package name: up to the first of =<>!~[ @;
    if [ -n "$name" ] && [ -x "$out/venv/bin/$name" ]; then ln -sf "$out/venv/bin/$name" "/usr/local/bin/$name"; fi
  done
fi

chmod -R a+rX "$out"
echo "paper tools: ${#apt_pkgs[@]} apt, ${#py_pkgs[@]} python"
