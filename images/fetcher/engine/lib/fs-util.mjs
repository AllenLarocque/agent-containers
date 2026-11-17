// Small read helpers for folders the research agent can also write to. Directories are
// walked with held descriptors (safe-write's openDirAt, O_DIRECTORY|O_NOFOLLOW at every
// step) and files are opened relative to the held descriptor with O_NOFOLLOW|O_NONBLOCK,
// so a component swapped for a link mid-read is never followed, and a FIFO cannot block.
import fs from 'node:fs';
import { openDirAt, viaFd } from './safe-write.mjs';

const { O_RDONLY, O_DIRECTORY, O_NOFOLLOW, O_NONBLOCK } = fs.constants;
const plainName = (s) => typeof s === 'string' && s !== '' && s !== '.' && s !== '..' && !s.includes('/') && !s.includes('\0');

// fn(dirFd) with root/<segs...> held open; null if a step is missing, a link or not a
// directory. The root itself is resolved once (it is the owner's mount path).
export function withDir(root, segs, fn) {
  const held = [];
  try {
    let fd;
    try {
      if (!segs.every(plainName)) return null;
      fd = fs.openSync(fs.realpathSync(root), O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
      held.push(fd);
      for (const s of segs) fd = openDirAt(fd, s, held, false);
    } catch {
      return null;
    }
    return fn(fd);
  } finally {
    for (const f of held) fs.closeSync(f);
  }
}

export const listAt = (dirFd) => fs.readdirSync(`/proc/self/fd/${dirFd}`);

// A small regular file, not through a link at its final name; null otherwise.
export function readSmall(file, max) {
  let fd;
  try {
    fd = fs.openSync(file, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    const st = fs.fstatSync(fd);
    if (!st.isFile() || st.size > max) return null;
    const buf = Buffer.alloc(st.size);
    const n = fs.readSync(fd, buf, 0, st.size, 0);
    return buf.subarray(0, n).toString('utf8');
  } catch {
    return null;
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

export const readSmallAt = (dirFd, name, max) => (plainName(name) ? readSmall(viaFd(dirFd, name), max) : null);

// True if file is a regular file (not a link at its final name) starting with prefix.
export function startsWith(file, prefix) {
  let fd;
  try {
    fd = fs.openSync(file, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    if (!fs.fstatSync(fd).isFile()) return false;
    const want = Buffer.from(prefix);
    const buf = Buffer.alloc(want.length);
    return fs.readSync(fd, buf, 0, want.length, 0) === want.length && buf.equals(want);
  } catch {
    return false;
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

export const startsWithAt = (dirFd, name, prefix) => plainName(name) && startsWith(viaFd(dirFd, name), prefix);
