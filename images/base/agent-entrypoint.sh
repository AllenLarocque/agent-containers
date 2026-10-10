#!/usr/bin/env bash
# The container's main process (compose `command`). Order matters: NOTHING that talks to the network
# starts before the firewall is up. If the firewall fails, the container exits (it stays closed).
set -uo pipefail
sudo /usr/local/bin/init-firewall.sh || { echo "[agent-entrypoint] firewall setup FAILED: exiting, nothing started"; exit 1; }
/usr/local/bin/agent-init.sh
/usr/local/bin/agent-t3 start
# RStudio Server only where the owner enabled it: the same read-only switch the firewall read.
if [ "$(cat /etc/firewall/rstudio 2>/dev/null)" = RSTUDIO=1 ]; then
  /usr/local/bin/agent-rstudio start
fi
exec sleep infinity
