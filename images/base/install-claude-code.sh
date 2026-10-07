#!/usr/bin/env bash
# Installs the pinned Claude Code at container start (called by agent-init.sh; also safe to run by
# hand). Claude Code is proprietary, so the PUBLIC images carry only the lockfile
# (/usr/local/lib/agent/claude-code), never the package itself.
#
# - Integrity: `npm ci` refuses any tarball whose sha512 differs from package-lock.json.
# - The INSTALL lives in the container's own layer (/opt/claude-code), so every `agent-up up`
#   (a recreate) starts from a fresh, verified copy: nothing an agent edits there persists or reaches
#   another project. Only npm's download CACHE is shared (volume npm-cache-shared), and npm checks
#   every cached tarball against the lockfile's sha512 before using it, so a poisoned entry is refused.
# - Keyed on CONTENT: the install dir is named by the lockfile's sha256 (CLAUDE_CODE_ID, image build).
# - Atomic: install into a private temp dir, then rename into place (a concurrent hand run is safe).
# Exit 0 = the pinned claude runs; non-zero = it does not (agent-init logs it, never fails the start).
set -euo pipefail
log(){ printf '[install-claude-code] %s\n' "$*"; }

SPEC=/usr/local/lib/agent/claude-code
ROOT=${CLAUDE_CODE_ROOT:-/opt/claude-code}
ID=$(cat "$SPEC/CLAUDE_CODE_ID")
WANT=$(jq -r '.dependencies["@anthropic-ai/claude-code"]' "$SPEC/package.json")
DEST="$ROOT/$ID"

works(){ "$1/node_modules/.bin/claude" --version 2>/dev/null | grep -qE "^${WANT//./\\.}( |$)"; }

if [ -d "$DEST" ] && works "$DEST"; then
  log "present: claude $WANT ($DEST)"; exit 0
fi
if [ -e "$DEST" ]; then  # a broken install (cannot come from our rename; e.g. a hand edit): set aside
  mv -T "$DEST" "$ROOT/.broken.$ID.$$" && log "WARN set aside a broken install: $ROOT/.broken.$ID.$$"
fi

TMP=$(mktemp -d "$ROOT/.tmp.$ID.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
cp "$SPEC/package.json" "$SPEC/package-lock.json" "$TMP/"
log "installing claude $WANT (npm ci, integrity-checked) ..."
npm ci --prefix "$TMP" --no-audit --no-fund --no-update-notifier --loglevel=warn
# The native binary is an OPTIONAL dependency: when its tarball fails the integrity check, npm skips it
# (nothing unverified is installed) and the wrapper silently falls back to the musl build. Refuse that.
case "$(uname -m)" in x86_64) arch=x64 ;; aarch64) arch=arm64 ;; *) arch="$(uname -m)" ;; esac
[ -d "$TMP/node_modules/@anthropic-ai/claude-code-linux-$arch" ] \
  || { log "ERROR native package claude-code-linux-$arch missing (failed integrity or download)"; exit 1; }
works "$TMP" || { log "ERROR installed claude does not report version $WANT"; exit 1; }

if mv -T "$TMP" "$DEST" 2>/dev/null; then
  trap - EXIT; log "installed: claude $WANT ($DEST)"
elif works "$DEST"; then
  log "a concurrent run installed it first: claude $WANT ($DEST)"
else
  log "ERROR could not move the install into place: $DEST"; exit 1
fi
