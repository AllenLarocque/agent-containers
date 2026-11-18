#!/usr/bin/env bash
# spades-fetcher's main process (the image CMD). Order matters:
#   1. the firewall: nothing that talks to the network starts before it is up; if it fails, exit (the
#      container stays closed). agent-up mounts PROFILE=research for the fetcher (open public egress,
#      private and link-local ranges denied).
#   2. the virtual display, started directly: xvfb-run hangs when it is PID 1's child in a container.
#   3. the owner's view (fetcher-view), ONLY when agent-up mounted a password (/etc/fetcher/view-password).
#   4. the engine, exec'd so it receives the container's stop signal.
# There is no agent here: this never runs agent-init, T3, or any agent CLI. Chromium's sandbox stays on
# (the container's seccomp profile allows it); nothing here passes a sandbox opt-out.
set -uo pipefail
log() { echo "[fetcher-entrypoint] $*"; }

sudo /usr/local/bin/init-firewall.sh || { log "firewall setup FAILED: exiting, nothing started"; exit 1; }

# Unix socket only (no TCP listener). A stale lock from an unclean stop would make Xvfb refuse :99.
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99
# Larger than the browser window (1280x900 page + its toolbar), so the address bar and the whole window fit in the view.
Xvfb :99 -screen 0 1440x1080x24 -nolisten tcp >/dev/null 2>&1 &
for _ in $(seq 100); do [ -S /tmp/.X11-unix/X99 ] && break; sleep 0.1; done
[ -S /tmp/.X11-unix/X99 ] || { log "Xvfb did not start on :99: exiting"; exit 1; }
export DISPLAY=:99

# ---- the owner's view (fetcher-view: x11vnc on the container's loopback + noVNC/websockify on 3773) ----
# Only when agent-up mounted /etc/fetcher/view-password (the owner set FETCH_VIEW_PORT); otherwise nothing listens.
# A viewer that fails to start is logged; the engine runs without it.
if [ -e /etc/fetcher/view-password ]; then
  /usr/local/bin/fetcher-view /etc/fetcher/view-password || log "the viewer did not start: running without it"
fi
# ---- end of the owner's view ----

exec node /opt/fetcher/fetcher.mjs
