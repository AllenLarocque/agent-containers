#!/usr/bin/env bash
# /usr/local/bin/<bin> (claude, codex, ...: symlinks to this file): runs the pinned agent CLI that
# install-agent-cli installed at container start. The tool is the one whose install.conf names this BIN.
name="${0##*/}"
conf=$(grep -lx "BIN=$name" /usr/local/lib/agent/clis/*/install.conf 2>/dev/null | head -n 1)
[ -n "$conf" ] || { echo "$name: no agent CLI is configured under this name" >&2; exit 127; }
dir="${conf%/install.conf}"; tool="${dir##*/}"
bin="${AGENT_CLI_ROOT:-/opt}/$tool/$(cat "$dir/INSTALL_ID")/node_modules/.bin/$name"
if [ ! -x "$bin" ]; then
  echo "$name: $(sed -n 's/^NAME=//p' "$conf") is not installed yet (it installs at container start)." >&2
  echo "        See the [install-$tool] lines in the container log, or run: install-$tool" >&2
  exit 127
fi
exec "$bin" "$@"
