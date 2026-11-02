#!/usr/bin/env node
'use strict';

// Enforces how T3 Code runs Codex, in $T3_BASE_DIR/userdata/settings.json (the t3-<project> named
// volume), at every container start, BEFORE `agent-t3 start`. Every other setting is kept as it is.
//
//   providerInstances.<id>.config.setupMode = "existing"   for every instance with driver "codex"
//
// T3 0.1.3 has two Codex setups. "existing" runs the Codex in the container (/usr/local/bin/codex,
// pinned by the image's lockfile) with its login in $CODEX_HOME. "managed" (one click in T3's
// provider settings) downloads T3's OWN, unpinned Codex into T3's base dir and wants a separate
// "Sign in with ChatGPT" inside T3. Until that finishes, T3 reports Codex as signed out ("Sign in with
// ChatGPT to use managed Codex.") while `codex` in a shell works (seen in spades_pe, 2026-11-02).
// Values verified against the t3 0.1.3 server bundle: setupMode is Literals(["managed", "existing"]),
// and only "managed" selects the managed driver.
//
// A missing file is fine (T3 creates it). An unreadable or invalid file is left alone, with a warning.
//
// Usage: node configure-t3-settings.js

const fs = require('fs');
const path = require('path');
const os = require('os');

const base = process.env.T3_BASE_DIR || path.join(os.homedir(), '.t3');
const settingsPath = path.join(base, 'userdata', 'settings.json');

if (!fs.existsSync(settingsPath)) {
  console.log(`No ${settingsPath} yet: T3 starts with Codex setup "existing"`);
  process.exit(0);
}

let settings;
try {
  settings = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
} catch (e) {
  console.error(`WARN ${settingsPath} not changed: ${e.message}`);
  process.exit(1);
}

const changed = [];
const instances = settings && typeof settings === 'object' ? settings.providerInstances : null;
if (instances && typeof instances === 'object') {
  for (const [id, inst] of Object.entries(instances)) {
    if (!inst || typeof inst !== 'object' || inst.driver !== 'codex') continue;
    const config = inst.config;
    if (config && typeof config === 'object' && config.setupMode === 'managed') {
      config.setupMode = 'existing';
      changed.push(id);
    }
  }
}

if (changed.length) {
  const tmp = `${settingsPath}.tmp.${process.pid}`;
  fs.writeFileSync(tmp, JSON.stringify(settings, null, 2) + '\n', { mode: fs.statSync(settingsPath).mode & 0o777 });
  fs.renameSync(tmp, settingsPath);
  console.log(`T3 Codex setup "managed" -> "existing" (instance ${changed.join(', ')}) in ${settingsPath}`);
} else {
  console.log(`T3 Codex setup is "existing" in ${settingsPath}`);
}
