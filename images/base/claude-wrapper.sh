#!/usr/bin/env bash
# /usr/local/bin/claude: runs the pinned Claude Code that install-claude-code.sh installed at container start.
bin="${CLAUDE_CODE_ROOT:-/opt/claude-code}/$(cat /usr/local/lib/agent/claude-code/CLAUDE_CODE_ID)/node_modules/.bin/claude"
if [ ! -x "$bin" ]; then
  echo "claude: Claude Code is not installed yet (it installs at container start)." >&2
  echo "        See the [install-claude-code] lines in the container log, or run: install-claude-code" >&2
  exit 127
fi
exec "$bin" "$@"
