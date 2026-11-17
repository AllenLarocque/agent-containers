// DOI validation. A request line is a DOI and nothing else: it is built into a URL
// (https://doi.org/<doi>) that a browser holding a login session will visit, and it
// comes from an AI that reads untrusted pages.
import { createHash } from 'node:crypto';

// Safe set: no whitespace, %, ?, #, @, backslash, quotes, or non-ASCII.
export const DOI_PATTERN = /^10\.[0-9]{4,9}\/[A-Za-z0-9._;()/:<>[\]-]{1,200}$/;

export function parseDoi(line) {
  if (typeof line !== 'string') return null;
  const doi = line.trim();             // validate before lower-casing: toLowerCase maps some non-ASCII to ASCII
  if (!DOI_PATTERN.test(doi)) return null;
  if (doi.includes('..')) return null;
  // A "." segment would be dropped by URL resolution and change the path.
  if (doi.split('/').some((seg) => seg === '.')) return null;
  return doi.toLowerCase();
}

// Folder name derived from the DOI only: sanitised for readability, hash for uniqueness.
// Callers pass parseDoi output; lower-casing here keeps the hash and the readable part
// in agreement even if they do not.
export function folderName(doi) {
  const lower = doi.toLowerCase();
  const readable = lower.replace(/[^a-z0-9]+/g, '_').slice(0, 100);
  const hash = createHash('sha256').update(lower).digest('hex').slice(0, 8);
  return `doi_${readable}_${hash}`;
}
