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
check "no ubuntugis PPA"               bash -c 'f=(/etc/apt/sources.list.d/); [ -f /etc/apt/sources.list ] && f+=(/etc/apt/sources.list); test -d /etc/apt/sources.list.d; set +e; grep -rqi ubuntugis "${f[@]}" >/dev/null 2>&1; test $? -eq 1'
check "tmux"                           tmux -V
check "exiftool"                       exiftool -ver
check "gh"                             gh --version
check "uv 0.12.19"                     bash -c 'uv --version | grep -qE "^uv 0\.12\.19( |$)"'
check "node 22"                        bash -c 'node --version | grep -q "^v22\."'
# Claude Code is proprietary and the images are public: ONLY the integrity-locked spec is baked in.
check "Claude Code NOT in the image"   bash -c '[ -z "$(find / -xdev \( -path /proc -o -path /sys \) -prune -o -path "*@anthropic-ai/claude-code*" -print -quit 2>/dev/null)" ]'
check "claude wrapper says not installed" bash -c 'out=$(claude --version 2>&1); [ $? -eq 127 ] && grep -q "not installed yet" <<<"$out"'
check "Claude Code lockfile has integrity" bash -c 'jq -e ".packages[\"node_modules/@anthropic-ai/claude-code\"].integrity | startswith(\"sha512-\")" /usr/local/lib/agent/claude-code/package-lock.json'
check "CLAUDE_CODE_ID matches the lockfile" bash -c '[ "$(cat /usr/local/lib/agent/claude-code/CLAUDE_CODE_ID)" = "$(sha256sum /usr/local/lib/agent/claude-code/package-lock.json | cut -c1-16)" ]'
check "/opt/claude-code owned by agent" bash -c '[ "$(stat -c %U /opt/claude-code)" = agent ]'
check "firewall script present"        test -x /usr/local/bin/init-firewall.sh
check "ip6tables present"             command -v ip6tables
check "allowlist dir present"          test -d /etc/firewall/allowlist.d
check "allowlist dir root-owned 755"   bash -c '[ "$(stat -c %U:%a /etc/firewall/allowlist.d)" = root:755 ]'
check "dnsmasq system user exists"     bash -c 'u=$(id -u dnsmasq) && [ "$u" -ne 0 ] && [ "$u" -ne 1000 ] && [ "$u" -lt 1000 ]'
check "conntrack present"              command -v conntrack
check "setpriv present"                command -v setpriv
check "sudo limited to firewall"       bash -c 'sudo -n -l | grep -q "/usr/local/bin/init-firewall.sh"'
# EXACTLY one sudo rule, and sudo's own environment hygiene on (the script also pins PATH/HOME).
sudo_cmds=$(sudo -n -l 2>/dev/null | awk 'f && NF {sub(/^[ \t]+/, ""); print} /may run the following commands/ {f=1}')
[ "$sudo_cmds" = "(root) NOPASSWD: /usr/local/bin/init-firewall.sh" ] && ok "sudo -l lists exactly the firewall script" \
  || bad "sudo -l commands are: $(printf '%q' "$sudo_cmds")"
check "sudo secure_path set"           bash -c 'sudo -n -l | grep -q "secure_path="'
check "sudo env_reset on"              bash -c 'sudo -n -l | grep -q "env_reset"'
# "The agent cannot become uid 997 (dnsmasq) or root" rests on this inventory: any new setuid binary
# or file capability must be reviewed and added here deliberately.
expect_suid='/usr/bin/chfn
/usr/bin/chsh
/usr/bin/gpasswd
/usr/bin/mount
/usr/bin/newgrp
/usr/bin/passwd
/usr/bin/su
/usr/bin/sudo
/usr/bin/umount'
# (find/getcap exit non-zero on unreadable paths, which pipefail + set -e would turn into a silent abort)
got_suid=$( { find / -xdev -perm -4000 -type f 2>/dev/null || true; } | LC_ALL=C sort)
[ "$got_suid" = "$expect_suid" ] && ok "setuid binaries match the reviewed list" \
  || { bad "setuid binaries differ from the reviewed list:"; diff <(echo "$expect_suid") <(echo "$got_suid") | sed 's/^/        /'; }
check "getcap present"                 command -v getcap
mapfile -t capdirs < <(find / -mindepth 1 -maxdepth 1 -type d ! -name proc ! -name sys ! -name dev)
got_caps=$( { getcap -r "${capdirs[@]}" 2>/dev/null || true; } | LC_ALL=C sort)
[ -z "$got_caps" ] && ok "no file capabilities anywhere" || { bad "file capabilities found:"; echo "$got_caps" | sed 's/^/        /'; }
check "dnsmasq account locked, no login shell" bash -c 'getent passwd dnsmasq | cut -d: -f7 | grep -Eq "(nologin|false)$"'
check "no ssh client in base (git uses HTTPS via gh)" bash -c '! command -v ssh'

check "PE/AI on disk at pinned commit" bash -c 'git -C /opt/reference/pe-ai rev-parse HEAD | grep -q "^e7ae689751316dfe742f31b32d0d659accd0cc41$"'
check "agent-init present"             test -x /usr/local/bin/agent-init.sh
check "agent-init succeeds"            bash -c 'CLAUDE_CONFIG_DIR=/tmp/cc /usr/local/bin/agent-init.sh'
check "agent-init installed the pinned claude" bash -c 'want=$(jq -r ".dependencies[\"@anthropic-ai/claude-code\"]" /usr/local/lib/agent/claude-code/package.json); claude --version | grep -qE "^${want//./\\.}( |$)"'
check "PE/AI plugins installed"        bash -c 'jq -e ".plugins | keys | map(select(test(\"@predictiveecology-ai$\"))) | length == 3" /tmp/cc/plugins/installed_plugins.json'
check "superpowers installed"          bash -c 'jq -e ".plugins | has(\"superpowers@superpowers-marketplace\")" /tmp/cc/plugins/installed_plugins.json'
check "NO hooks in settings"           bash -c 'jq -e "has(\"hooks\") | not" /tmp/cc/settings.json'

[ "$fail" -eq 0 ] && echo "SMOKE base: ALL PASSED" || { echo "SMOKE base: FAILURES"; exit 1; }
