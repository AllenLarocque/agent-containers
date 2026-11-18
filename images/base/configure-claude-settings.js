#!/usr/bin/env node
'use strict';

// Pre-configures the claude-hud statusline and display options, and
// disables the extra --dangerously-skip-permissions confirmation prompt, makes bypassPermissions the default mode,
// written into $CLAUDE_CONFIG_DIR (the claude-<project> named volume, see the
// compose seed in project-template/config) and seeded with this content on first
// container start. Also denies the paper-search Sci-Hub tools, and registers that MCP server in the
// research container only (see below).
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

// Paper discovery: the paper-search MCP server (images/research/paper-tools/python.txt), registered
// for the research container only (the one whose profile file says PROFILE=research). Its Sci-Hub
// tools are denied by name in every container (owner decision: no shadow libraries; use_scihub is never
// set). The research image also ships this list as root-owned Claude managed settings
// (images/research/claude-managed-settings.json). tests/smoke/research-offline.sh fails if the two
// lists differ, or if any tool the server serves that mentions Sci-Hub is missing from either, so a
// version bump that adds or renames one cannot slip through.
const PAPER_SEARCH = '/opt/paper-tools/venv/bin/paper-search-mcp';
const PAPER_SEARCH_DENY = ['download_scihub', 'download_with_fallback'].map((t) => `mcp__paper-search__${t}`);
const profileFile = process.env.AGENT_PROFILE_FILE || '/etc/firewall/profile';  // override: smoke tests only
let research = false;
try {
  research = fs.readFileSync(profileFile, 'utf8').trim() === 'PROFILE=research';
} catch (e) { /* absent = builder */ }
const deny = Array.isArray(json.permissions.deny) ? json.permissions.deny : [];
json.permissions.deny = deny.concat(PAPER_SEARCH_DENY.filter((r) => !deny.includes(r)));

// Hooks ship DISABLED until the user's hooks review (spec §8). Fail loudly if anything set them.
if (Object.prototype.hasOwnProperty.call(json, 'hooks')) {
  console.error('configure-claude-settings: refusing to keep a "hooks" key (hooks are disabled by policy)');
  delete json.hooks;
}

fs.writeFileSync(settingsPath, JSON.stringify(json, null, 2) + '\n');
console.log(`Wrote statusLine + skipDangerousModePermissionPrompt + defaultMode=bypassPermissions + the paper-search Sci-Hub deny rules to ${settingsPath}`);

// The server is a user-scope MCP server in $CLAUDE_CONFIG_DIR/.claude.json (where `claude mcp add
// --scope user` writes; written here because agent-init may run before claude is installed). Its start
// command: a scratch working folder, so a call without save_path (default ./downloads) never writes
// into the session's folder; a clean environment, so the server gets only the contact email (Unpaywall,
// OpenAlex; empty = unset) and the CORE key (empty = unset; only the $CORE_API_KEY reference is written here, never its value) and no token, other key or ~/.config/paper-search-mcp/.env. Variables are written
// $NAME, never ${NAME}: Claude treats ${NAME} in MCP args as its own expansion syntax, which could put
// the value into the shell text. A failure here warns and leaves the file alone: the container still
// starts, without the server.
const paperSearchStart = 'mkdir -p "$HOME/.cache/paper-search" && cd "$HOME/.cache/paper-search" && '
  + 'exec env -i HOME="$HOME" PATH="$PATH" PAPER_SEARCH_MCP_ENV_FILE=/dev/null '
  + 'PAPER_SEARCH_MCP_UNPAYWALL_EMAIL="$RESEARCH_CONTACT_EMAIL" PAPER_SEARCH_MCP_OPENALEX_EMAIL="$RESEARCH_CONTACT_EMAIL" '
  + 'PAPER_SEARCH_MCP_CORE_API_KEY="$CORE_API_KEY" '
  + PAPER_SEARCH;
try {
  const claudeJsonPath = path.join(claudeDir, '.claude.json');
  const claudeJson = fs.existsSync(claudeJsonPath) ? JSON.parse(fs.readFileSync(claudeJsonPath, 'utf8')) : {};
  const servers = claudeJson.mcpServers || {};
  let installed = true;
  try { fs.accessSync(PAPER_SEARCH, fs.constants.X_OK); } catch (e) { installed = false; }
  if (research && !installed) console.error(`configure-claude-settings: WARN ${PAPER_SEARCH} missing: paper-search is unavailable`);
  const had = Object.prototype.hasOwnProperty.call(servers, 'paper-search');
  if (research && installed) {
    servers['paper-search'] = { type: 'stdio', command: '/bin/sh', args: ['-c', paperSearchStart], env: {} };
  } else {
    delete servers['paper-search'];
  }
  if ((research && installed) || had) {
    claudeJson.mcpServers = servers;
    const tmp = `${claudeJsonPath}.tmp.${process.pid}`;
    fs.writeFileSync(tmp, JSON.stringify(claudeJson, null, 2) + '\n', { mode: 0o600 });
    fs.renameSync(tmp, claudeJsonPath);
    console.log(research && installed ? `Registered the paper-search MCP server in ${claudeJsonPath}` : `Removed paper-search from ${claudeJsonPath} (not the research container)`);
  }
} catch (e) {
  console.error(`configure-claude-settings: WARN paper-search not registered: ${e.message}`);
}

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
