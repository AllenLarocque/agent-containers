#!/usr/bin/env node
'use strict';

// Pre-configures the claude-hud statusline and display options, and
// disables the extra --dangerously-skip-permissions confirmation prompt, makes bypassPermissions the default mode,
// written into $CLAUDE_CONFIG_DIR (the claude-<project> named volume, see the
// compose seed in project-template/config) and seeded with this content on first
// container start.
//
// Usage: node configure-claude-settings.js <node-runtime-path>

const fs = require('fs');
const path = require('path');
const os = require('os');

const claudeDir = process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
const settingsPath = path.join(claudeDir, 'settings.json');
const hudConfigPath = path.join(claudeDir, 'plugins', 'claude-hud', 'config.json');
const runtimePath = process.argv[2];

if (!runtimePath) {
  console.error('Usage: configure-claude-settings.js <node-runtime-path>');
  process.exit(1);
}

fs.mkdirSync(claudeDir, { recursive: true });

let json = {};
if (fs.existsSync(settingsPath)) {
  json = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
}

// The whole script is later wrapped in an outer bash -c '...' (see below),
// so any single quote here would otherwise close that outer string early.
// Q is the standard bash trick for embedding a literal single quote inside
// a single-quoted string: close the quote, emit it via a double-quoted
// segment, then reopen the quote.
const Q = '\'"\'"\'';

const statuslineScript = [
  'cols=${COLUMNS:-}',
  `case "$cols" in ""|*[!0-9]*) cols=$(stty size </dev/tty 2>/dev/null | awk ${Q}{print $2}${Q});; esac`,
  'case "$cols" in ""|*[!0-9]*) cols=120;; esac',
  'export COLUMNS=$(( cols > 4 ? cols - 4 : 1 ))',
  `plugin_dir=$(ls -d "\${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/plugins/cache/*/claude-hud/*/ 2>/dev/null | awk -F/ ${Q}{ print $(NF-1) "\\t" $(0) }${Q} | grep -E ${Q}^[0-9]+\\.[0-9]+\\.[0-9]+[[:space:]]${Q} | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -1 | cut -f2-)`,
  `exec "${runtimePath}" "\${plugin_dir}dist/index.js"`,
].join('; ');

json.statusLine = {
  type: 'command',
  command: `bash -c '${statuslineScript}'`,
};
json.skipDangerousModePermissionPrompt = true;
// Owner decision 2026-10-07: builder containers default to bypassPermissions (= --dangerously-skip-
// permissions). The container is the safety boundary (firewall, scoped token, merge gate), not prompts.
json.permissions = Object.assign({}, json.permissions, { defaultMode: 'bypassPermissions' });

// Hooks ship DISABLED until the user's hooks review (spec §8). Fail loudly if anything set them.
if (Object.prototype.hasOwnProperty.call(json, 'hooks')) {
  console.error('configure-claude-settings: refusing to keep a "hooks" key (hooks are disabled by policy)');
  delete json.hooks;
}

fs.writeFileSync(settingsPath, JSON.stringify(json, null, 2) + '\n');
console.log(`Wrote statusLine + skipDangerousModePermissionPrompt + defaultMode=bypassPermissions to ${settingsPath}`);

// Unlike settings.json above, this file is left alone if it already exists:
// it's the same file /claude-hud:configure writes to, so once a volume has
// one (seeded by us or hand-edited by the user), reapplying our defaults on
// every rebuild would silently discard their customization.
if (!fs.existsSync(hudConfigPath)) {
  const hudConfig = {
    language: 'en',
    lineLayout: 'expanded',
    showSeparators: false,
    display: {
      showModel: true,
      showContextBar: true,
      showTools: true,
      showSkills: true,
      showMcp: true,
      showAgents: true,
      showTodos: true,
      showProject: true,
      showAddedDirs: true,
      showConfigCounts: true,
      showTokenBreakdown: true,
      showSpeed: true,
      showCost: true,
      showUsage: true,
      showResetLabel: true,
      showSessionName: true,
      showDuration: true,
      showSessionTokens: true,
      showEffortLevel: true,
      showOutputStyle: true,
      showMemoryUsage: true,
      showPromptCache: true,
      showClaudeCodeVersion: true,
      showCompactions: true,
      showAdvisor: true,
    },
    gitStatus: {
      enabled: true,
      showDirty: true,
      showAheadBehind: false,
      showFileStats: false,
    },
  };

  fs.mkdirSync(path.dirname(hudConfigPath), { recursive: true });
  fs.writeFileSync(hudConfigPath, JSON.stringify(hudConfig, null, 2) + '\n');
  console.log(`Wrote claude-hud display config to ${hudConfigPath}`);
} else {
  console.log(`claude-hud display config already exists at ${hudConfigPath}, leaving it alone`);
}
