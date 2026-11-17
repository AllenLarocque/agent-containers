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

// ---- fix round 1 ----
const shortWriter = (max) => (fd, buf, off, len) => fs.writeSync(fd, buf, off, Math.min(len, max));
const noTemps = (d) => assert.deepEqual(listing(d).filter((n) => n.startsWith('.tmp-')), []);

test('short writes are looped: the whole content lands', () => {
  const { root } = sandbox();
  const data = 'x'.repeat(1000);
  writeFileInside(root, 'a.txt', data, { write: shortWriter(7) });
  assert.equal(fs.readFileSync(path.join(root, 'a.txt'), 'utf8'), data);
});

test('a write error leaves neither the final file nor a temp file, and keeps an older file', () => {
  const { root } = sandbox();
  writeFileInside(root, 'a.txt', 'old');
  let calls = 0;
  const failing = (fd, buf, off, len) => { if (++calls === 2) throw new Error('ENOSPC'); return fs.writeSync(fd, buf, off, Math.min(len, 3)); };
  assert.throws(() => writeFileInside(root, 'a.txt', 'new content', { write: failing }), /ENOSPC/);
  assert.equal(fs.readFileSync(path.join(root, 'a.txt'), 'utf8'), 'old');
  writeFileInside(root, 'd/b.txt', 'ok');
  calls = 0;
  assert.throws(() => writeFileInside(root, 'd/c.txt', 'new content', { write: failing }), /ENOSPC/);
  assert.equal(fs.existsSync(path.join(root, 'd/c.txt')), false);
  noTemps(root); noTemps(path.join(root, 'd'));
});

test('a zero-byte write is an error, not a spin', () => {
  const { root } = sandbox();
  assert.throws(() => writeFileInside(root, 'a.txt', 'abc', { write: () => 0 }), /no progress/);
  assert.equal(fs.existsSync(path.join(root, 'a.txt')), false);
  noTemps(root);
});

test('moveInside: a failure mid-copy leaves no final file and no temp, and keeps the source', () => {
  const { base, root } = sandbox();
  const src = path.join(base, 'dl.tmp');
  fs.writeFileSync(src, 'abcdefghij');
  let calls = 0;
  const failing = (fd, buf, off, len) => { if (++calls === 2) throw new Error('EIO'); return fs.writeSync(fd, buf, off, Math.min(len, 3)); };
  assert.throws(() => moveInside(src, root, 'p/paper.pdf', { write: failing }), /EIO/);
  assert.equal(fs.existsSync(path.join(root, 'p/paper.pdf')), false);
  noTemps(path.join(root, 'p'));
  assert.equal(fs.readFileSync(src, 'utf8'), 'abcdefghij');
});

test('created directories are exactly 755 under umask 077; the file is 644', () => {
  const { root } = sandbox();
  const old = process.umask(0o077);
  try { writeFileInside(root, 'a/b/c.txt', 'x'); } finally { process.umask(old); }
  assert.equal(fs.statSync(path.join(root, 'a')).mode & 0o777, 0o755);
  assert.equal(fs.statSync(path.join(root, 'a/b')).mode & 0o777, 0o755);
  assert.equal(fs.statSync(path.join(root, 'a/b/c.txt')).mode & 0o777, 0o644);
});

test('a verified directory swapped for a symlink between two writes is refused', () => {
  const { root, outside } = sandbox();
  writeFileInside(root, 'x/one.txt', '1');
  fs.renameSync(path.join(root, 'x'), path.join(root, 'x.moved'));
  fs.symlinkSync(outside, path.join(root, 'x'));
  assert.throws(() => writeFileInside(root, 'x/two.txt', '2'), EscapeError);
  assert.deepEqual(listing(outside), []);
});

test('race: directory swapped for a link after it was opened -> write stays in the opened directory', () => {
  const { root, outside } = sandbox();
  const swap = () => {
    fs.renameSync(path.join(root, 'x'), path.join(root, 'x.moved'));
    fs.symlinkSync(outside, path.join(root, 'x'));
  };
  writeFileInside(root, 'x/a.txt', 'warm');
  writeFileInside(root, 'x/b.txt', 'raced', { beforeCreate: swap });
  assert.deepEqual(listing(outside), []);
  assert.equal(fs.readFileSync(path.join(root, 'x.moved', 'b.txt'), 'utf8'), 'raced');
  noTemps(path.join(root, 'x.moved'));
});

test('race: same swap during moveInside never lands at the link target', () => {
  const { base, root, outside } = sandbox();
  writeFileInside(root, 'x/a.txt', 'warm');
  const src = path.join(base, 'dl.tmp');
  fs.writeFileSync(src, '%PDF-');
  moveInside(src, root, 'x/p.pdf', { beforeCreate: () => {
    fs.renameSync(path.join(root, 'x'), path.join(root, 'x.moved'));
    fs.symlinkSync(outside, path.join(root, 'x'));
  } });
  assert.deepEqual(listing(outside), []);
  assert.equal(fs.readFileSync(path.join(root, 'x.moved', 'p.pdf'), 'utf8'), '%PDF-');
});

test('no descriptor is leaked on refusals', () => {
  const { root, outside } = sandbox();
  fs.symlinkSync(outside, path.join(root, 'link'));
  const before = fs.readdirSync('/proc/self/fd').length;
  for (let i = 0; i < 50; i++) {
    assert.throws(() => writeFileInside(root, 'link/z.txt', 'no'), EscapeError);
    assert.throws(() => writeFileInside(root, 'q/r.txt', 'x', { write: () => { throw new Error('x'); } }));
  }
  assert.equal(fs.readdirSync('/proc/self/fd').length, before);
});

// ---- Task 2 follow-ups ----
test('a cleanup failure never masks the original error', () => {
  const { root } = sandbox();
  // During the write, swap the temp name for a non-empty directory so rmSync(tmp) throws.
  const swapTemp = () => {
    const t = listing(root).find((n) => n.startsWith('.tmp-'));
    fs.renameSync(path.join(root, t), path.join(root, 'moved-away'));
    fs.mkdirSync(path.join(root, t));
    fs.writeFileSync(path.join(root, t, 'f'), 'x');
    throw new Error('ENOSPC original');
  };
  assert.throws(() => writeFileInside(root, 'a.txt', 'abc', { write: swapTemp }), /ENOSPC original/);
  assert.equal(fs.existsSync(path.join(root, 'a.txt')), false);
});
