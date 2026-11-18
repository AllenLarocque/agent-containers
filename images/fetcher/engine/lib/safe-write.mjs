// Writes into a folder the research agent (another container on the same bind mount)
// can also write to at any moment, and can plant symbolic links in.
//
// LINUX ONLY by design: directories are walked with held descriptors and every later
// step goes through /proc/self/fd/<dirfd>/<name>, so no step re-resolves a path through
// components an attacker can swap.
//   1. The root is resolved once (realpath, so the root itself may be reached through a
//      link, e.g. a mount path) and opened O_DIRECTORY|O_NOFOLLOW.
//   2. Each component is opened relative to the previous directory descriptor with
//      O_DIRECTORY|O_NOFOLLOW (created first with mkdir when missing). A link, or a
//      non-directory, is an EscapeError. O_NOFOLLOW applies to <name>; <dirfd> is a held
//      descriptor, not a path lookup.
//   3. The temp file (O_EXCL|O_NOFOLLOW) and the final rename both go through the last
//      directory descriptor, so they land in the directory that was opened, even if that
//      directory is renamed or replaced by a link afterwards. rename replaces a link
//      sitting at the final name; it never follows it.
// Residual: none known inside the root. The root's own ancestors are resolved once at
// the start by realpath; they are the owner's mount path, not attacker-writable.
//
// What this does NOT guarantee: the research container runs as the same uid and has
// read-write access to the same folder, so it can replace or delete any file there at
// any time, including right after we write it. The guarantee is only that the
// FETCHER's own writes never land outside the root or through a link; it is not that
// the bytes found later at a final name are the ones the fetcher wrote.
import fs from 'node:fs';
import path from 'node:path';
import { randomBytes } from 'node:crypto';

export class EscapeError extends Error {
  constructor(message) {
    super(message);
    this.name = 'EscapeError';
  }
}

const { O_WRONLY, O_CREAT, O_EXCL, O_NOFOLLOW, O_RDONLY, O_DIRECTORY } = fs.constants;
export const viaFd = (fd, name) => `/proc/self/fd/${fd}/${name}`;

function parts(relPath) {
  if (typeof relPath !== 'string' || relPath === '' || relPath.includes('\0') || path.isAbsolute(relPath))
    throw new EscapeError('bad relative path');
  const segs = relPath.split('/');
  if (segs.some((s) => s === '' || s === '.' || s === '..')) throw new EscapeError('bad relative path');
  return segs;
}

// Opens <name> under a held directory descriptor, O_DIRECTORY|O_NOFOLLOW, pushing the new
// descriptor onto held. create=false (readers) never makes the directory.
export function openDirAt(parentFd, name, held, create = true) {
  const p = viaFd(parentFd, name);
  let created = false;
  if (create) {
    try { fs.mkdirSync(p, { mode: 0o755 }); created = true; } catch (e) { if (e.code !== 'EEXIST') throw e; }
  }
  let fd;
  try {
    fd = fs.openSync(p, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
  } catch (e) {
    if (e.code === 'ELOOP' || e.code === 'ENOTDIR') throw new EscapeError(`not a plain directory: ${name}`);
    throw e;
  }
  held.push(fd);
  if (created) fs.fchmodSync(fd, 0o755);   // exactly 755 whatever the umask
  return fd;
}

// Short writes are looped over; a zero-byte write is an error rather than a spin.
function writeAll(fd, buf, write) {
  for (let off = 0; off < buf.length;) {
    const n = write(fd, buf, off, buf.length - off);
    if (!(n > 0)) throw new Error('write made no progress');
    off += n;
  }
}

// opts (tests only): write(fd, buf, off, len) replaces fs.writeSync; beforeCreate()
// runs after the parent directory is opened and before the temp file is created.
function place(root, relPath, fill, opts) {
  const segs = parts(relPath);
  const name = segs.pop();
  const held = [];
  let tmp;
  try {
    const rootFd = fs.openSync(fs.realpathSync(root), O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    held.push(rootFd);
    let dir = rootFd;
    for (const seg of segs) dir = openDirAt(dir, seg, held);
    opts.beforeCreate?.();
    const st = fs.lstatSync(viaFd(dir, name), { throwIfNoEntry: false });
    if (st && !st.isFile()) throw new EscapeError(`not a plain file: ${name}`);
    tmp = viaFd(dir, `.tmp-${randomBytes(8).toString('hex')}`);
    const fd = fs.openSync(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644);
    try {
      fs.fchmodSync(fd, 0o644);
      fill(fd, opts.write ?? fs.writeSync);
    } finally {
      fs.closeSync(fd);
    }
    fs.renameSync(tmp, viaFd(dir, name));
    tmp = undefined;
  } catch (e) {
    // Best effort: a cleanup failure (e.g. the temp name was swapped for a directory)
    // must never replace the error that got us here.
    if (tmp) { try { fs.rmSync(tmp, { force: true }); } catch { /* keep e */ } }
    throw e;
  } finally {
    for (const fd of held) fs.closeSync(fd);
  }
}

export function writeFileInside(root, relPath, data, opts = {}) {
  const buf = typeof data === 'string' ? Buffer.from(data) : data;
  place(root, relPath, (fd, write) => writeAll(fd, buf, write), opts);
}

// Copies tmpPath (a regular file, not a link) into place, then removes it. A copy
// rather than a bare rename because the download folder is usually another filesystem.
// On any failure nothing is left in the destination and the source is kept.
export function moveInside(tmpPath, root, relPath, opts = {}) {
  let src;
  try {
    src = fs.openSync(tmpPath, O_RDONLY | O_NOFOLLOW);
    if (!fs.fstatSync(src).isFile()) throw new EscapeError('source is not a plain file');
    place(root, relPath, (fd, write) => {
      const buf = Buffer.allocUnsafe(1 << 20);
      for (let n; (n = fs.readSync(src, buf, 0, buf.length, null)) > 0;) writeAll(fd, buf.subarray(0, n), write);
    }, opts);
  } catch (e) {
    if (e.code === 'ELOOP') throw new EscapeError('source is a symbolic link');
    throw e;
  } finally {
    if (src !== undefined) fs.closeSync(src);
  }
  fs.rmSync(tmpPath, { force: true });
}
