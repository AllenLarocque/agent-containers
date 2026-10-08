#!/usr/bin/env node
'use strict';

// Enforces the managed Codex defaults in $CODEX_HOME/config.toml (the codex-<project> named volume,
// see the compose seed in project-template/config), at every container start. Every OTHER line of
// the file (the user's own keys, comments, tables) is kept as it is.
//
//   approval_policy = "never"                  the container (firewall, scoped token, merge gate) is
//   sandbox_mode = "danger-full-access"        the safety boundary, not prompts or Codex's own sandbox
//   check_for_update_on_startup = false        the pinned version is the only version (lockfile + rebuild)
//   [analytics] enabled = false                OpenAI analytics default ON in the TUI
//
// Key names verified against openai/codex codex-rs/config/src/config_toml.rs + types.rs (0.162.0).
// Node has no TOML parser, so this is a deliberately small LINE editor: a managed key found at its
// place (top level, or inside [analytics]) is rewritten in place; a missing one is added (top-level
// keys at the top of the file, where TOML always allows them; [analytics] at the end, or into the
// user's existing [analytics] table). Lines inside multi-line strings are never touched.
//
// Usage: node configure-codex-config.js

const fs = require('fs');
const path = require('path');
const os = require('os');

const codexHome = process.env.CODEX_HOME || path.join(os.homedir(), '.codex');
const configPath = path.join(codexHome, 'config.toml');

// Full dotted key -> TOML value.
const MANAGED = {
  approval_policy: '"never"',
  sandbox_mode: '"danger-full-access"',
  check_for_update_on_startup: 'false',
  'analytics.enabled': 'false',
};

// `a . "b"` -> `a.b` (bare and quoted key parts; enough for the keys we manage).
const norm = (k) => k.split('.').map((p) => p.trim().replace(/^(["'])(.*)\1$/, '$2')).join('.');

function apply(text) {
  const lines = text.length ? text.replace(/\r\n/g, '\n').replace(/\n$/, '').split('\n') : [];
  const seen = new Set();
  const drop = new Set();
  let table = '';            // '' = top level
  let analyticsHeader = -1;  // line index of an [analytics] header, if any
  let inString = null;       // open multi-line string delimiter

  lines.forEach((line, i) => {
    if (inString) {
      if (line.split(inString).length % 2 === 0) inString = null;
      return;
    }
    const header = line.match(/^\s*\[(\[?)([^\]]+)\]\]?\s*(#.*)?$/);
    if (header) {
      table = norm(header[2]) + (header[1] ? '[]' : '');
      if (table === 'analytics') analyticsHeader = i;
      return;
    }
    const kv = line.match(/^\s*((?:[A-Za-z0-9_-]+|"[^"]*"|'[^']*')(?:\s*\.\s*(?:[A-Za-z0-9_-]+|"[^"]*"|'[^']*'))*)\s*=(.*)$/);
    if (!kv) return;
    const key = norm(kv[1]);
    const full = table ? `${table}.${key}` : key;
    if (full in MANAGED) {
      if (seen.has(full)) drop.add(i);
      else { lines[i] = `${key} = ${MANAGED[full]}`; seen.add(full); }
    } else if (full === 'analytics') {   // inline table: analytics = { ... } (TOML: one line)
      if (seen.has('analytics.enabled')) drop.add(i);
      else { lines[i] = `analytics = { enabled = ${MANAGED['analytics.enabled']} }`; seen.add('analytics.enabled'); }
    }
    for (const d of ['"""', "'''"]) {
      if (kv[2].split(d).length % 2 === 0) { inString = d; break; }
    }
  });

  let out = lines.filter((_, i) => !drop.has(i));
  if (!seen.has('analytics.enabled')) {
    if (analyticsHeader >= 0) {
      const at = out.indexOf(lines[analyticsHeader]);
      out.splice(at + 1, 0, `enabled = ${MANAGED['analytics.enabled']}`);
    } else {
      if (out.length && out[out.length - 1].trim() !== '') out.push('');
      out.push('[analytics]', `enabled = ${MANAGED['analytics.enabled']}`);
    }
  }
  const top = Object.keys(MANAGED).filter((k) => !k.includes('.') && !seen.has(k));
  if (top.length) {
    out = ['# Managed by agent-containers (configure-codex-config.js): re-applied at every container start.',
      ...top.map((k) => `${k} = ${MANAGED[k]}`), ...(out.length ? [''] : []), ...out];
  }
  return out.join('\n') + '\n';
}

fs.mkdirSync(codexHome, { recursive: true });
const before = fs.existsSync(configPath) ? fs.readFileSync(configPath, 'utf8') : '';
const after = apply(before);
if (after !== before) {
  const tmp = `${configPath}.tmp.${process.pid}`;
  fs.writeFileSync(tmp, after);
  fs.renameSync(tmp, configPath);
}
console.log(`Enforced approval_policy=never, sandbox_mode=danger-full-access, check_for_update_on_startup=false, analytics.enabled=false in ${configPath}`);
