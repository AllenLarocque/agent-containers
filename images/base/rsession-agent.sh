#!/usr/bin/env bash
# rserver.conf rsession-path (spec §13.3): sets up an R session's environment, then execs the real rsession.
#
# 1. The container environment. rserver starts every rsession with a SCRUBBED environment (PATH,
#    LANG, HOME, USER, SHELL + RStudio's and R's own variables), so R in RStudio would otherwise lack
#    what R in the agent's shell has: GH_TOKEN (GitHub API limits for Require/remotes; the project's
#    scoped agent token, spec §5), the other project.env secrets, TZ, CLAUDE_CONFIG_DIR, ... We add the
#    environment rserver itself was started with (agent-rstudio: the container's, minus OP_*), read
#    from /proc/<rserver>/environ: nothing is written to disk. RStudio's own values always win, and
#    OP_* (1Password) and RS_*/RSTUDIO_* (RStudio's control variables) are never passed on. If the
#    parent is not rserver, or its environment is unreadable, the session starts with RStudio's
#    environment only (logged).
# 2. RS_INITIAL_PROJECT: the first session of this container opens the project's .Rproj (when
#    /workspace has exactly one), so R starts in /workspace and sources its .Rprofile, which is how
#    setupProject's library takes effect. Only the FIRST: RS_INITIAL_PROJECT overrides RStudio's own
#    project switching, so later sessions (a project switch, a restart) follow RStudio's choice.
set -uo pipefail
REAL=/usr/lib/rstudio-server/bin/rsession
STATE=/var/lib/rstudio-agent
warn(){ printf '[rsession-agent] WARN %s\n' "$*" >&2; }

declare -A have=()
while IFS= read -r k; do have[$k]=1; done < <(compgen -e)
if [ "$(cat "/proc/$PPID/comm" 2>/dev/null)" = rserver ] && [ -r "/proc/$PPID/environ" ]; then
  while IFS= read -r -d '' kv; do
    k=${kv%%=*}
    [[ $k =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    case $k in OP_*|RS_*|RSTUDIO_*|RSTUDIO|PWD|OLDPWD|SHLVL|_) continue ;; esac
    [ -n "${have[$k]:-}" ] && continue
    export "${kv?}"   # NAME=value from rserver's environment
  done < "/proc/$PPID/environ"
else
  warn "parent is not a readable rserver: this R session gets RStudio's environment only"
fi

if [ -z "${RS_INITIAL_PROJECT:-}" ] && mkdir "$STATE/initial-project-done" 2>/dev/null; then
  shopt -s nullglob
  projs=(/workspace/*.Rproj)
  shopt -u nullglob
  [ "${#projs[@]}" -eq 1 ] && export RS_INITIAL_PROJECT="${projs[0]}"
fi
exec "$REAL" "$@"
