#!/usr/bin/env bash
# spades-fetcher's main process (the image CMD). Order matters:
#   1. the firewall: nothing that talks to the network starts before it is up; if it fails, exit (the
#      container stays closed). agent-up mounts PROFILE=research for the fetcher (open public egress,
#      private and link-local ranges denied).
#   2. the virtual display, started directly: xvfb-run hangs when it is PID 1's child in a container.
#   3. the owner's view, ONLY when the owner configured a password (/etc/fetcher/view-password).
#   4. the engine, exec'd so it receives the container's stop signal.
# There is no agent here: this never runs agent-init, T3, or any agent CLI. Chromium's sandbox stays on
# (the container's seccomp profile allows it); nothing here passes a sandbox opt-out.
set -uo pipefail
log() { echo "[fetcher-entrypoint] $*"; }

sudo /usr/local/bin/init-firewall.sh || { log "firewall setup FAILED: exiting, nothing started"; exit 1; }

# Unix socket only (no TCP listener). A stale lock from an unclean stop would make Xvfb refuse :99.
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99
Xvfb :99 -screen 0 1280x900x24 -nolisten tcp >/dev/null 2>&1 &
for _ in $(seq 100); do [ -S /tmp/.X11-unix/X99 ] && break; sleep 0.1; done
[ -S /tmp/.X11-unix/X99 ] || { log "Xvfb did not start on :99: exiting"; exit 1; }
export DISPLAY=:99

# ---- VIEWER HOOK (Task 5: x11vnc on the container's loopback + noVNC/websockify) ----
# Does nothing when /etc/fetcher/view-password is absent (the viewer is off unless the owner set a port).
if [ -e /etc/fetcher/view-password ]; then
  log "a view password is mounted, but this image version has no viewer yet: not starting one"
fi
# ---- END VIEWER HOOK ----

exec node /opt/fetcher/fetcher.mjs
