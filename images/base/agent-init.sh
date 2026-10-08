#!/usr/bin/env bash
# Runs as `agent` at container start (after the firewall). Idempotent. NEVER fails the start:
# every step is guarded and the script always exits 0, logging what it could not do.
set -uo pipefail
log(){ printf '[agent-init] %s\n' "$*"; }
export CLAUDE_CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
mkdir -p "$CLAUDE_CONFIG_DIR" "$CODEX_HOME"

# 0. The agent CLIs themselves (not in the image; see install-agent-cli.sh): every tool with a spec.
#    Claude's plugins and settings below need claude.
for spec in /usr/local/lib/agent/clis/*/; do
  t=$(basename "$spec")
  /usr/local/bin/install-agent-cli "$t" || log "WARN $t NOT installed: it is unavailable in this container (and anything below that needs it)"
done

# 1. Plugins. PE/AI from the PINNED local checkout (same commit as /opt/reference/pe-ai, so
#    plugin and reading copy cannot disagree); personal plugins from GitHub.
add_mkt(){ claude plugin marketplace add "$1" >/dev/null 2>&1 && log "marketplace: $1" || log "WARN marketplace add failed: $1"; }
inst(){ claude plugin install "$1" >/dev/null 2>&1 && log "plugin: $1" || log "WARN plugin install failed: $1"; }
add_mkt /opt/reference/pe-ai
add_mkt obra/superpowers-marketplace
add_mkt jarrodwatts/claude-hud
add_mkt zoharbabin/claude-code-message-timestamps
for p in shared-conventions spades-toolkit-suite landr-suite; do inst "$p@predictiveecology-ai"; done
inst superpowers@superpowers-marketplace
inst claude-hud@claude-hud
inst message-timestamps@zoharbabin-claude-tools

# 2. Settings. Claude: statusLine, no hooks. Codex: no analytics, no update check, the container is the sandbox.
node /usr/local/lib/agent/configure-claude-settings.js "$(command -v node)" || log "WARN settings not written"
node /usr/local/lib/agent/configure-codex-config.js || log "WARN codex config not written"

# 3. GitHub: gh reads GH_TOKEN (tier A, scoped agent token) directly; make git use gh.
if [ -n "${GH_TOKEN:-}" ]; then
  gh auth setup-git >/dev/null 2>&1 && log "git uses gh credentials (agent identity)" || log "WARN gh setup-git failed"
  # Commit as the agent account (its GitHub no-reply address), unless an identity is already set.
  if [ -z "$(git config --global user.email 2>/dev/null)" ]; then
    if who=$(gh api user --jq '"\(.login) \(.id)"' 2>/dev/null) && [ -n "$who" ]; then
      login=${who% *}; uid=${who#* }
      git config --global user.name "$login" \
        && git config --global user.email "${uid}+${login}@users.noreply.github.com" \
        && log "git identity: $login <${uid}+${login}@users.noreply.github.com>"
    else
      log "WARN could not read the agent's GitHub identity; set git user.name/user.email by hand"
    fi
  fi
else
  log "NOTE: no GH_TOKEN — GitHub write access disabled in this container"
fi
exit 0
