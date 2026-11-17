import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { writeFileInside, moveInside, EscapeError } from '../lib/safe-write.mjs';

function sandbox() {
  const base = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'sw-')));
  const root = path.join(base, 'root');
  const outside = path.join(base, 'outside');
  fs.mkdirSync(root);
  fs.mkdirSync(outside);
  return { base, root, outside };
}
const listing = (d) => fs.readdirSync(d).sort();

test('writes a file, creates parents, modes 755 and 644, no temp left', () => {
  const { root } = sandbox();
  const old = process.umask(0o077);
  try { writeFileInside(root, 'x/y.txt', 'hi'); } finally { process.umask(old); }
  assert.equal(fs.readFileSync(path.join(root, 'x/y.txt'), 'utf8'), 'hi');
  assert.equal(fs.statSync(path.join(root, 'x/y.txt')).mode & 0o777, 0o644);
  assert.deepEqual(listing(path.join(root, 'x')), ['y.txt']);
});

test('overwrites an existing regular file and accepts Buffers', () => {
  const { root } = sandbox();
  writeFileInside(root, 'a.bin', Buffer.from([1, 2]));
  writeFileInside(root, 'a.bin', Buffer.from([3]));
  assert.deepEqual([...fs.readFileSync(path.join(root, 'a.bin'))], [3]);
});

test('symlinked intermediate directory is refused', () => {
  const { root, outside } = sandbox();
  fs.symlinkSync(outside, path.join(root, 'link'));
  assert.throws(() => writeFileInside(root, 'link/z.txt', 'no'), EscapeError);
  assert.deepEqual(listing(outside), []);
});

test('symlinked deeper intermediate directory is refused', () => {
  const { root, outside } = sandbox();
  fs.mkdirSync(path.join(root, 'a'));
  fs.symlinkSync(outside, path.join(root, 'a', 'b'));
  assert.throws(() => writeFileInside(root, 'a/b/c/z.txt', 'no'), EscapeError);
  assert.deepEqual(listing(outside), []);
});

test('symlinked final file is refused and its target untouched', () => {
  const { root, outside } = sandbox();
  fs.writeFileSync(path.join(outside, 'f'), 'orig');
  fs.mkdirSync(path.join(root, 'x'));
  fs.symlinkSync(path.join(outside, 'f'), path.join(root, 'x', 'f.txt'));
  assert.throws(() => writeFileInside(root, 'x/f.txt', 'no'), EscapeError);
  assert.equal(fs.readFileSync(path.join(outside, 'f'), 'utf8'), 'orig');
});

test('dangling symlink as final file is refused', () => {
  const { root, outside } = sandbox();
  fs.symlinkSync(path.join(outside, 'nope'), path.join(root, 'd.txt'));
  assert.throws(() => writeFileInside(root, 'd.txt', 'no'), EscapeError);
  assert.equal(fs.existsSync(path.join(outside, 'nope')), false);
});

test('.. and absolute relative paths are refused', () => {
  const { root, base } = sandbox();
  for (const rel of ['../up.txt', 'a/../../up.txt', 'a/..', '/etc/x', '/', '', '.', 'a\0b'])
    assert.throws(() => writeFileInside(root, rel, 'no'), EscapeError, JSON.stringify(rel));
  assert.equal(fs.existsSync(path.join(base, 'up.txt')), false);
  assert.equal(fs.existsSync('/etc/x'), false);
});

test('a directory in the way of the final file is refused', () => {
  const { root } = sandbox();
  fs.mkdirSync(path.join(root, 'd'));
  assert.throws(() => writeFileInside(root, 'd', 'no'), EscapeError);
});

test('a file in the way of a parent directory is refused', () => {
  const { root } = sandbox();
  fs.writeFileSync(path.join(root, 'f'), 'x');
  assert.throws(() => writeFileInside(root, 'f/g.txt', 'no'), EscapeError);
});

test('root reached through a symlink: resolved once, writes land in the real root', () => {
  const { base, root } = sandbox();
  const viaLink = path.join(base, 'rootlink');
  fs.symlinkSync(root, viaLink);
  writeFileInside(viaLink, 'k/v.txt', 'ok');
  assert.equal(fs.readFileSync(path.join(root, 'k/v.txt'), 'utf8'), 'ok');
});

test('root reached through a symlink still refuses links inside it', () => {
  const { base, root, outside } = sandbox();
  const viaLink = path.join(base, 'rootlink');
  fs.symlinkSync(root, viaLink);
  fs.symlinkSync(outside, path.join(root, 'link'));
  assert.throws(() => writeFileInside(viaLink, 'link/z.txt', 'no'), EscapeError);
});

test('a missing root is an error, not created', () => {
  const { base } = sandbox();
  assert.throws(() => writeFileInside(path.join(base, 'nope'), 'a.txt', 'x'));
  assert.equal(fs.existsSync(path.join(base, 'nope')), false);
});

test('moveInside copies a regular file into place and removes the source', () => {
  const { base, root } = sandbox();
  const src = path.join(base, 'dl.tmp');
  fs.writeFileSync(src, '%PDF-1.7 body');
  moveInside(src, root, 'p/paper.pdf');
  assert.equal(fs.readFileSync(path.join(root, 'p/paper.pdf'), 'utf8'), '%PDF-1.7 body');
  assert.equal(fs.statSync(path.join(root, 'p/paper.pdf')).mode & 0o777, 0o644);
  assert.equal(fs.existsSync(src), false);
  assert.deepEqual(listing(path.join(root, 'p')), ['paper.pdf']);
});

test('moveInside refuses the same escapes', () => {
  const { base, root, outside } = sandbox();
  const src = path.join(base, 'dl.tmp');
  fs.writeFileSync(src, 'data');
  fs.symlinkSync(outside, path.join(root, 'link'));
  assert.throws(() => moveInside(src, root, 'link/z.pdf'), EscapeError);
  assert.throws(() => moveInside(src, root, '../z.pdf'), EscapeError);
  assert.throws(() => moveInside(src, root, '/etc/z.pdf'), EscapeError);
  assert.deepEqual(listing(outside), []);
  assert.equal(fs.existsSync(src), true);
});

test('moveInside refuses a symlink as the source', () => {
  const { base, root, outside } = sandbox();
  fs.writeFileSync(path.join(outside, 'secret'), 'secret');
  const src = path.join(base, 'dl.tmp');
  fs.symlinkSync(path.join(outside, 'secret'), src);
  assert.throws(() => moveInside(src, root, 'p.pdf'), EscapeError);
  assert.equal(fs.existsSync(path.join(root, 'p.pdf')), false);
});
