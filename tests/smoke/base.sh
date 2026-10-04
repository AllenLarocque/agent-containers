#!/usr/bin/env bash
# Smoke test for spades-base. Runs INSIDE the image as the default user.
set -euo pipefail
fail=0
ok()   { echo "OK:   $*"; }
bad()  { echo "FAIL: $*"; fail=1; }
check(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

[ "$(id -u)" = "1000" ] && [ "$(id -un)" = "agent" ] && ok "user agent uid 1000" || bad "user is $(id -un)/$(id -u), want agent/1000"
check "R starts"                       Rscript -e 'invisible(1)'
check "R is 4.5.3"                     Rscript -e 'stopifnot(getRversion() == "4.5.3")'
check "Require loads"                  Rscript -e 'library(Require)'
check "SpaDES.project loads"           Rscript -e 'library(SpaDES.project)'
check "SpaDES.core NOT preinstalled"   Rscript -e 'stopifnot(!requireNamespace("SpaDES.core", quietly = TRUE))'
check "terra NOT preinstalled"         Rscript -e 'stopifnot(!requireNamespace("terra", quietly = TRUE))'
check "gdalinfo"                       gdalinfo --version
check "gdal can write+read a GeoTIFF"  bash -c 'gdal_create -outsize 2 2 -bands 1 -burn 1 -of GTiff /tmp/s.tif && gdalinfo /tmp/s.tif | grep -q "Driver: GTiff"'
check "geos/proj present"              bash -c 'dpkg -s libgeos-dev libproj-dev libudunits2-dev'
check "no ubuntugis PPA"               bash -c '! grep -rqi ubuntugis /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null'
check "tmux"                           tmux -V
check "exiftool"                       exiftool -ver
check "gh"                             gh --version
check "uv 0.12.19"                     bash -c 'uv --version | grep -q "0.12.19"'
check "node 22"                        bash -c 'node --version | grep -q "^v22\."'
check "claude 2.1.289"                 bash -c 'claude --version | grep -q "2.1.289"'
check "firewall script present"        test -x /usr/local/bin/init-firewall.sh
check "allowlist dir present"          test -d /etc/firewall/allowlist.d
check "sudo limited to firewall"       bash -c 'sudo -n -l | grep -q "/usr/local/bin/init-firewall.sh"'

check "PE/AI on disk at pinned commit" bash -c 'git -C /opt/reference/pe-ai rev-parse HEAD | grep -q "^e7ae689751316dfe742f31b32d0d659accd0cc41$"'
check "agent-init present"             test -x /usr/local/bin/agent-init.sh
check "agent-init succeeds"            bash -c 'CLAUDE_CONFIG_DIR=/tmp/cc /usr/local/bin/agent-init.sh'
check "PE/AI plugins installed"        bash -c 'jq -e ".plugins | keys | map(select(test(\"@predictiveecology-ai$\"))) | length == 3" /tmp/cc/plugins/installed_plugins.json'
check "superpowers installed"          bash -c 'jq -e ".plugins | has(\"superpowers@superpowers-marketplace\")" /tmp/cc/plugins/installed_plugins.json'
check "NO hooks in settings"           bash -c 'jq -e "has(\"hooks\") | not" /tmp/cc/settings.json'

[ "$fail" -eq 0 ] && echo "SMOKE base: ALL PASSED" || { echo "SMOKE base: FAILURES"; exit 1; }
