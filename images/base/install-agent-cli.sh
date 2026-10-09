#!/usr/bin/env bash
# Installs a pinned agent CLI (Claude Code, Codex, ...) at container start (called by agent-init.sh;
# also safe to run by hand). Usage: install-agent-cli <tool>, or through its symlink install-<tool>
# (install-claude-code, install-codex). The PUBLIC images never redistribute vendor agent binaries
# (Claude Code is proprietary): they carry only each tool's lockfile (/usr/local/lib/agent/clis/<tool>,
# from images/base/agent-clis/<tool>). Adding a tool = adding that directory (see the Dockerfile).
#
# - Integrity: `npm ci` refuses any tarball whose sha512 differs from package-lock.json.
# - The INSTALL lives in the container's own layer (/opt/<tool>), so every `agent-up up` (a recreate)
#   starts from a fresh, verified copy: nothing an agent edits there persists or reaches another
#   project. Only npm's download CACHE is shared (volume npm-cache-shared), and npm checks every
#   cached tarball against the lockfile's sha512 before using it, so a poisoned entry is refused.
# - Keyed on CONTENT: the install dir is named by the lockfile's sha256 (INSTALL_ID, image build).
# - Atomic: install into a private temp dir, then rename into place (a concurrent hand run is safe).
# Exit 0 = the pinned CLI runs; non-zero = it does not (agent-init logs it, never fails the start).
set -euo pipefail

tool="${0##*/}"; tool="${tool#install-}"
if [ "$tool" = agent-cli ]; then tool="${1:-}"; fi
log(){ printf '[install-%s] %s\n' "$tool" "$*"; }
case "$tool" in ""|*[!a-z0-9-]*) echo "usage: install-agent-cli <tool>  (a directory under /usr/local/lib/agent/clis)" >&2; exit 2 ;; esac

SPEC=/usr/local/lib/agent/clis/$tool
[ -f "$SPEC/install.conf" ] || { log "ERROR unknown agent CLI: no $SPEC/install.conf"; exit 2; }
conf(){ sed -n "s/^$1=//p" "$SPEC/install.conf" | tail -n 1; }
PKG=$(conf PACKAGE); BIN=$(conf BIN)
ROOT=${AGENT_CLI_ROOT:-/opt}/$tool
ID=$(cat "$SPEC/INSTALL_ID")
WANT=$(jq -r --arg p "$PKG" '.dependencies[$p]' "$SPEC/package.json")
DEST="$ROOT/$ID"

# `claude --version` prints "2.1.289 (Claude Code)", `codex --version` "codex-cli 0.162.0".
works(){ "$1/node_modules/.bin/$BIN" --version 2>/dev/null | grep -qE "(^| )${WANT//./\\.}( |$)"; }

if [ -d "$DEST" ] && works "$DEST"; then
  log "present: $BIN $WANT ($DEST)"; exit 0
fi
if [ -e "$DEST" ]; then  # a broken install (cannot come from our rename; e.g. a hand edit): set aside
  mv -T "$DEST" "$ROOT/.broken.$ID.$$" && log "WARN set aside a broken install: $ROOT/.broken.$ID.$$"
fi

TMP=$(mktemp -d "$ROOT/.tmp.$ID.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
cp "$SPEC/package.json" "$SPEC/package-lock.json" "$TMP/"
log "installing $BIN $WANT (npm ci, integrity-checked) ..."
npm ci --prefix "$TMP" --no-audit --no-fund --no-update-notifier --loglevel=warn
# The native binary is an OPTIONAL dependency: when its tarball fails the integrity check, npm skips it
# (nothing unverified is installed) and the launcher silently falls back to another build or fails
# later with a vaguer message. Refuse that here. NATIVE (install.conf) names the package that must exist.
# Checked in npm's own record of what it installed (node_modules/.package-lock.json): a failed
# extraction can leave a partial directory behind (seen 2026-10-08: ENOTEMPTY on cleanup).
case "$(uname -m)" in x86_64) arch=x64 ;; aarch64) arch=arm64 ;; *) arch="$(uname -m)" ;; esac
native=$(conf NATIVE); native=${native//\{arch\}/$arch}
[ -z "$native" ] || jq -e --arg k "node_modules/$native" '.packages | has($k)' "$TMP/node_modules/.package-lock.json" >/dev/null 2>&1 \
  || { log "ERROR native package $native missing (failed integrity or download)"; exit 1; }
works "$TMP" || { log "ERROR installed $BIN does not report version $WANT"; exit 1; }

if mv -T "$TMP" "$DEST" 2>/dev/null; then
  trap - EXIT; log "installed: $BIN $WANT ($DEST)"
elif works "$DEST"; then
  log "a concurrent run installed it first: $BIN $WANT ($DEST)"
else
  log "ERROR could not move the install into place: $DEST"; exit 1
fi
