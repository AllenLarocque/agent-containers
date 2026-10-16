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
# Agent CLIs are vendor software and the images are public: ONLY the integrity-locked specs are baked in.
check "Claude Code NOT in the image"   bash -c '[ -z "$(find / -xdev \( -path /proc -o -path /sys \) -prune -o -path "*@anthropic-ai/claude-code*" -print -quit 2>/dev/null)" ]'
check "Codex NOT in the image"         bash -c '[ -z "$(find / -xdev \( -path /proc -o -path /sys \) -prune -o -path "*@openai/codex*" -print -quit 2>/dev/null)" ]'
check "claude wrapper says not installed" bash -c 'out=$(claude --version 2>&1); [ $? -eq 127 ] && grep -q "not installed yet" <<<"$out"'
check "codex wrapper says not installed"  bash -c 'out=$(codex --version 2>&1); [ $? -eq 127 ] && grep -q "not installed yet" <<<"$out"'
check "Claude Code lockfile has integrity" bash -c 'jq -e ".packages[\"node_modules/@anthropic-ai/claude-code\"].integrity | startswith(\"sha512-\")" /usr/local/lib/agent/clis/claude-code/package-lock.json'
# The integrity guard's NATIVE package must be in the lockfile WITH a hash (else npm ci could not verify it).
check "Codex lockfile has integrity (wrapper + linux-x64 native)" bash -c 'jq -e "[.packages[\"node_modules/@openai/codex\", \"node_modules/@openai/codex-linux-x64\"] | .integrity // \"\" | startswith(\"sha512-\")] == [true, true]" /usr/local/lib/agent/clis/codex/package-lock.json'
for t in claude-code codex; do
  check "$t: INSTALL_ID matches the lockfile" bash -c '[ "$(cat "/usr/local/lib/agent/clis/$1/INSTALL_ID")" = "$(sha256sum "/usr/local/lib/agent/clis/$1/package-lock.json" | cut -c1-16)" ]' _ "$t"
  check "$t: /opt/$t owned by agent"     bash -c '[ "$(stat -c %U "/opt/$1")" = agent ]' _ "$t"
  check "$t: install-$t on PATH"          command -v "install-$t"
done
# Every named-volume mount point must exist agent-owned (a missing one becomes a root-owned volume).
check "/home/agent/.codex owned by agent" bash -c '[ "$(stat -c %U /home/agent/.codex)" = agent ]'
check "CODEX_HOME=/home/agent/.codex"   test "${CODEX_HOME:-}" = /home/agent/.codex
check "install-agent-cli refuses an unknown tool" bash -c '! install-agent-cli ../etc 2>/dev/null && ! install-agent-cli nosuchtool 2>/dev/null'
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
check "t3 0.1.0 (pinned)"              bash -c 't3 --version 2>/dev/null | grep -qE "(^|[^0-9.])0\.1\.0([^0-9.]|$)"'
check "T3CODE_TELEMETRY_ENABLED=false set (t3 docs/user/telemetry.md; its PostHog host is not allowlisted either)" test "${T3CODE_TELEMETRY_ENABLED:-}" = false
check "entrypoint + agent-t3 present"  test -x /usr/local/bin/agent-entrypoint -a -x /usr/local/bin/agent-t3
# RStudio Server (spec §13.3): installed, pinned, configured; started only where the owner enabled it.
check "RStudio Server 2026.09.0+174 (pinned)" bash -c '/usr/lib/rstudio-server/bin/rstudio-server version | grep -q "^2026\.09\.0+174 "'
check "agent-rstudio present"           test -x /usr/local/bin/agent-rstudio
# The image is public: no cookie key, RPC key or database minted at build time may ship in it.
check "no RStudio keys or database baked in" bash -c '[ -z "$(find / -xdev \( -path /proc -o -path /sys \) -prune -o \( -name secure-cookie-key -o -name session-rpc-key -o -name "rstudio-os.sqlite*" \) -print 2>/dev/null)" ]'
check "/var/lib/rstudio-agent agent-owned, 700" bash -c '[ "$(stat -c %U:%a /var/lib/rstudio-agent)" = agent:700 ] && [ -z "$(ls -A /var/lib/rstudio-agent)" ]'
check "/home/agent/.local/share/rstudio owned by agent (volume mount point)" bash -c '[ "$(stat -c %U /home/agent/.local/share/rstudio)" = agent ]'
# --check-config reports every unrecognised rserver.conf key and exits non-zero.
check "rserver accepts rserver.conf (--check-config, as agent)" /usr/lib/rstudio-server/bin/rserver --check-config
check "rserver.conf: sign-in required, as agent, via rstudio-auth" bash -c 'c=/etc/rstudio/rserver.conf; for l in auth-none=0 server-user=agent auth-pam-helper-path=/usr/local/lib/agent/rstudio-auth rsession-path=/usr/local/lib/agent/rsession-agent rsession-which-r=/usr/local/bin/R www-port=8787; do grep -qx "$l" "$c" || exit 1; done'
check "rsession.conf: no suspend, /workspace, assistants off" bash -c 'c=/etc/rstudio/rsession.conf; for l in session-timeout-minutes=0 session-default-working-dir=/workspace session-default-new-project-dir=/workspace copilot-enabled=0 allow-copilot=0 allow-posit-assistant=0 posit-assistant-enabled=0 posit-assistant-installation-enabled=0; do grep -qx "$l" "$c" || exit 1; done; ! grep -q "^r-libs-user" "$c"'
check "RStudio config files root-owned, not agent-writable" bash -c 'for f in /etc/rstudio/rserver.conf /etc/rstudio/rsession.conf /etc/rstudio/agent-database.conf /etc/rstudio/file-locks /etc/rstudio/rstudio-prefs.json /usr/local/lib/agent/rstudio-auth /usr/local/lib/agent/rsession-agent; do [ "$(stat -c %U "$f")" = root ] && [ ! -w "$f" ] || exit 1; done'
# Copilot dropped from the image (owner decision 2026-10-10: size), pinned off in config; Quarto kept (pandoc).
check "Copilot language server NOT in the image" bash -c '[ ! -e /usr/lib/rstudio-server/bin/copilot-language-server-js ] && [ -z "$(find /usr/lib/rstudio-server -iname "*copilot-language-server*" 2>/dev/null)" ]'
check "rstudio-prefs.json: copilot_enabled false (valid JSON)" bash -c '[ "$(jq -r .copilot_enabled /etc/rstudio/rstudio-prefs.json)" = false ]'
check "RStudio's Quarto + pandoc present (R Markdown knitting)" bash -c 'q=/usr/lib/rstudio-server/bin/quarto; [ -x "$q/bin/quarto" ] && find "$q" -name pandoc -type f -perm -u+x | grep -q .'
check "RSTUDIO_DISABLE_CHECK_FOR_UPDATES=1" test "${RSTUDIO_DISABLE_CHECK_FOR_UPDATES:-}" = 1
# rstudio-auth fails closed without the owner's password file (none is mounted in the smoke test).
check "rstudio-auth refuses without the password file" bash -c '[ ! -e /run/secrets/rstudio-password ] && ! printf "%s" anything-long-enough-123 | /usr/local/lib/agent/rstudio-auth agent rstudio 1'
check "agent-init succeeds"            bash -c 'CLAUDE_CONFIG_DIR=/tmp/cc /usr/local/bin/agent-init.sh'
check "agent-init installed the pinned claude" bash -c 'want=$(jq -r ".dependencies[\"@anthropic-ai/claude-code\"]" /usr/local/lib/agent/clis/claude-code/package.json); claude --version | grep -qE "^${want//./\\.}( |$)"'
check "agent-init installed the pinned codex"  bash -c 'want=$(jq -r ".dependencies[\"@openai/codex\"]" /usr/local/lib/agent/clis/codex/package.json); codex --version | grep -qE "^codex-cli ${want//./\\.}$"'
check "PE/AI plugins installed"        bash -c 'jq -e ".plugins | keys | map(select(test(\"@predictiveecology-ai$\"))) | length == 3" /tmp/cc/plugins/installed_plugins.json'
check "superpowers installed"          bash -c 'jq -e ".plugins | has(\"superpowers@superpowers-marketplace\")" /tmp/cc/plugins/installed_plugins.json'
check "NO hooks in settings"           bash -c 'jq -e "has(\"hooks\") | not" /tmp/cc/settings.json'
check "default permission mode = bypassPermissions" bash -c 'jq -e ".permissions.defaultMode == \"bypassPermissions\"" /tmp/cc/settings.json'
check "codex config.toml: managed defaults" bash -c 'c=$(cat /home/agent/.codex/config.toml); for l in "approval_policy = \"never\"" "sandbox_mode = \"danger-full-access\"" "check_for_update_on_startup = false" "[analytics]" "enabled = false"; do grep -qxF "$l" <<<"$c" || exit 1; done'
# login status loads (and so validates) config.toml: a parse error prints "Error loading configuration".
check "codex accepts that config.toml"  bash -c 'codex login status 2>&1 | grep -q "Not logged in"'
# A user's own keys survive and a conflicting analytics setting is overridden (codex still parses it).
check "codex config: user keys kept, analytics enforced" bash -c '
  set -e; d=$(mktemp -d); printf "model = \"o3\"\napproval_policy = \"on-request\"\n[analytics]\nenabled = true\n[tui]\nnotifications = true\n" > "$d/config.toml"
  CODEX_HOME="$d" node /usr/local/lib/agent/configure-codex-config.js >/dev/null
  grep -qx "model = \"o3\"" "$d/config.toml"; grep -qx "notifications = true" "$d/config.toml"
  if grep -Eq "enabled = true|on-request" "$d/config.toml"; then exit 1; fi   # (set -e ignores `! cmd`)
  cp "$d/config.toml" "$d/once"; CODEX_HOME="$d" node /usr/local/lib/agent/configure-codex-config.js >/dev/null; cmp "$d/once" "$d/config.toml"
  CODEX_HOME="$d" codex login status 2>&1 | grep -q "Not logged in"'
check "zsh: .zshrc present, # comments work" zsh -ic 'echo ok # a comment' 
# agent-init sets the git identity from the agent's GitHub account (stub gh: no token needed here).
check "agent-init sets git identity from gh" bash -c '
  set -e; d=$(mktemp -d); mkdir -p "$d/bin" "$d/home"
  printf "#!/bin/sh\ncase \"\$1 \$2\" in \"api user\") echo \"agent-x 42\";; esac\nexit 0\n" > "$d/bin/gh"; chmod +x "$d/bin/gh"
  HOME="$d/home" PATH="$d/bin:$PATH" GH_TOKEN=dummy CLAUDE_CONFIG_DIR=/tmp/cc /usr/local/bin/agent-init.sh >/dev/null 2>&1
  [ "$(HOME="$d/home" git config --global user.email)" = "42+agent-x@users.noreply.github.com" ]
  [ "$(HOME="$d/home" git config --global user.name)" = "agent-x" ]'

[ "$fail" -eq 0 ] && echo "SMOKE base: ALL PASSED" || { echo "SMOKE base: FAILURES"; exit 1; }
