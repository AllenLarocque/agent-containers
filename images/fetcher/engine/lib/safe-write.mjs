// Writes into a folder the research agent can also write to (and can plant symbolic
// links in). Rules: the root is resolved ONCE (realpath, so the root itself may be
// reached through a link, e.g. a mount path); below it, every existing component is
// checked with lstat and a link anywhere is an error; the parent is re-resolved and
// must be exactly where the walk says it is; files are created with O_EXCL|O_NOFOLLOW
// in the target directory and renamed into place (rename replaces a link, never
// follows it).
// Residual: a process that swaps a directory for a link between the final check and
// the open can still win a race. Node has no openat; the files written are PDFs and
// text, and the fetcher runs one write at a time.
import fs from 'node:fs';
import path from 'node:path';
import { randomBytes } from 'node:crypto';

export class EscapeError extends Error {
  constructor(message) {
    super(message);
    this.name = 'EscapeError';
  }
}

const { O_WRONLY, O_CREAT, O_EXCL, O_NOFOLLOW, O_RDONLY } = fs.constants;

function parts(relPath) {
  if (typeof relPath !== 'string' || relPath === '' || relPath.includes('\0') || path.isAbsolute(relPath))
    throw new EscapeError('bad relative path');
  const segs = relPath.split('/');
  if (segs.some((s) => s === '' || s === '.' || s === '..')) throw new EscapeError('bad relative path');
  return segs;
}

// Returns { dir, name }: dir is an existing real directory inside the root.
function prepare(root, relPath) {
  const segs = parts(relPath);
  const name = segs.pop();
  const realRoot = fs.realpathSync(root);
  if (!fs.statSync(realRoot).isDirectory()) throw new EscapeError('root is not a directory');
  let dir = realRoot;
  for (const seg of segs) {
    const next = path.join(dir, seg);
    let st = fs.lstatSync(next, { throwIfNoEntry: false });
    if (!st) {
      try { fs.mkdirSync(next, { mode: 0o755 }); } catch (e) { if (e.code !== 'EEXIST') throw e; }
      st = fs.lstatSync(next);
    }
    if (st.isSymbolicLink() || !st.isDirectory()) throw new EscapeError(`not a plain directory: ${seg}`);
    dir = next;
  }
  if (fs.realpathSync(dir) !== dir || !(dir === realRoot || dir.startsWith(realRoot + path.sep)))
    throw new EscapeError('resolved outside the root');
  const final = path.join(dir, name);
  const st = fs.lstatSync(final, { throwIfNoEntry: false });
  if (st && !st.isFile()) throw new EscapeError(`not a plain file: ${name}`);
  return { dir, final };
}

function place(root, relPath, fill) {
  const { dir, final } = prepare(root, relPath);
  const tmp = path.join(dir, `.tmp-${randomBytes(8).toString('hex')}`);
  const fd = fs.openSync(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644);
  try {
    fs.fchmodSync(fd, 0o644);
    try { fill(fd); } finally { fs.closeSync(fd); }
    fs.renameSync(tmp, final);
  } catch (e) {
    fs.rmSync(tmp, { force: true });
    throw e;
  }
}

export function writeFileInside(root, relPath, data) {
  place(root, relPath, (fd) => fs.writeSync(fd, typeof data === 'string' ? Buffer.from(data) : data));
}

// Copies tmpPath (a regular file, not a link) into place, then removes it. A copy
// rather than a bare rename because the download folder is usually another filesystem.
export function moveInside(tmpPath, root, relPath) {
  let src;
  try {
    src = fs.openSync(tmpPath, O_RDONLY | O_NOFOLLOW);
    if (!fs.fstatSync(src).isFile()) throw new EscapeError('source is not a plain file');
    place(root, relPath, (fd) => {
      const buf = Buffer.allocUnsafe(1 << 20);
      for (let n; (n = fs.readSync(src, buf, 0, buf.length, null)) > 0;) {
        for (let off = 0; off < n;) off += fs.writeSync(fd, buf, off, n - off);
      }
    });
  } catch (e) {
    if (e.code === 'ELOOP') throw new EscapeError('source is a symbolic link');
    throw e;
  } finally {
    if (src !== undefined) fs.closeSync(src);
  }
  fs.rmSync(tmpPath, { force: true });
}
