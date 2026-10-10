#!/usr/bin/env bash
# RStudio Server inside the container (spec §13.3), opt-in per project (RSTUDIO=1 in project.conf).
#   agent-rstudio start    start rserver in the background, as the agent (idempotent)
# agent-entrypoint calls it only when the owner's read-only switch /etc/firewall/rstudio says RSTUDIO=1.
# rserver listens on container port 8787; compose publishes it on the HOST's loopback only
# (127.0.0.1:<RSTUDIO_PORT>), and the firewall accepts it only from the container's gateway (the host).
# Its settings are /etc/rstudio/{rserver,rsession}.conf (root-owned, baked into the image). Sign-in:
# user `agent` + the owner's per-project password file (rstudio-auth). NEVER fails the start: it
# always exits 0, logging what it could not do.
set -uo pipefail
log(){ printf '[agent-rstudio] %s\n' "$*"; }
RSERVER=/usr/lib/rstudio-server/bin/rserver
PORT=8787
STATE=/var/lib/rstudio-agent                       # agent-owned, in the container's own layer
PWFILE=/run/secrets/rstudio-password               # the owner's file, mounted read-only by agent-up
LOGDIR="${XDG_DATA_HOME:-$HOME/.local/share}/rstudio"   # the rstudio-<project> volume
LOG="$LOGDIR/agent-rserver.log"

answers(){ [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:$PORT/" 2>/dev/null)" != 000 ]; }

case "${1:-}" in
  start)
    [ -x "$RSERVER" ] || { log "WARN rserver not installed in this image"; exit 0; }
    mkdir -p "$LOGDIR" "$STATE/data" "$STATE/db" || { log "WARN cannot create $LOGDIR or $STATE"; exit 0; }
    if answers; then log "already running on :$PORT"; exit 0; fi
    # Sign-in needs the owner's password file, readable by the agent (host uid 1000, spec §3.1).
    # Without it every sign-in fails (rstudio-auth fails closed); the server still starts.
    if [ ! -r "$PWFILE" ] || [ ! -s "$PWFILE" ]; then
      log "WARN $PWFILE missing or unreadable: no one can sign in (run agent-up up on the host; host uid must be 1000)"
    fi
    # The server's environment = this one minus 1Password tokens (they should never be in the
    # container anyway). rsession-agent passes it on to R sessions (see that file).
    mapfile -t drop < <(compgen -e | grep -E '^OP_' || true)
    env_args=(); for k in "${drop[@]}"; do env_args+=(-u "$k"); done
    setsid nohup env "${env_args[@]}" "$RSERVER" --server-daemonize=0 >>"$LOG" 2>&1 </dev/null &
    for _ in $(seq 1 30); do
      answers && { log "server up on :$PORT (RStudio Server $(/usr/lib/rstudio-server/bin/rstudio-server version 2>/dev/null | head -n 1); log: $LOG)"; exit 0; }
      sleep 1
    done
    log "WARN server did not answer on :$PORT within 30 s (see $LOG and $LOGDIR/log/)"
    exit 0 ;;
  *) echo "usage: agent-rstudio start" >&2; exit 2 ;;
esac
