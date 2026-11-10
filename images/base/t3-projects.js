#!/usr/bin/env node
'use strict';

// Prints T3 Code's live (not removed) projects, one per line: <workspace root><TAB><title>.
// Read-only: `agent-t3 projects` uses it to report projects outside the container's project folders.
// T3 has no `project list` command (0.1.7), so this reads its state database directly. The table and
// file names are T3's own and may change with a T3 update: any failure exits 1 and the caller says
// "could not read", it never guesses.
//
// Usage: node --no-warnings t3-projects.js      (--no-warnings: node:sqlite is still "experimental")

const fs = require('fs');
const path = require('path');
const os = require('os');

const dir = path.join(process.env.T3_BASE_DIR || path.join(os.homedir(), '.t3'), 'userdata');

try {
  const { DatabaseSync } = require('node:sqlite');
  // T3 0.1.3 wrote state.sqlite, 0.1.7 writes statev2.sqlite and keeps the old file: take the newest.
  const mtime = (f) => Math.max(...[f, `${f}-wal`].map((p) => (fs.existsSync(p) ? fs.statSync(p).mtimeMs : 0)));
  if (!fs.existsSync(dir)) process.exit(0); // T3 has never started here: no projects
  const files = fs.readdirSync(dir).filter((f) => /^state(v\d+)?\.sqlite$/.test(f)).map((f) => path.join(dir, f));
  if (!files.length) process.exit(0); // T3 has not started yet: no projects
  files.sort((a, b) => mtime(b) - mtime(a));
  const db = new DatabaseSync(files[0], { readOnly: true });
  const rows = db.prepare('SELECT workspace_root, title FROM projection_projects WHERE deleted_at IS NULL ORDER BY workspace_root').all();
  for (const r of rows) console.log(`${r.workspace_root}\t${String(r.title).replace(/[\t\r\n]/g, ' ')}`);
} catch (e) {
  console.error(`t3-projects: ${e.message}`);
  process.exit(1);
}
