// Politeness limits, persisted so a restart does not reset them. Counts are per UTC
// day; the gaps use the last record times. `now()` returns milliseconds.
// The state file lives on a volume only the fetcher mounts, so reading it with plain
// fs is fine; it is still written with the same no-follow temp+rename as everything else.
import fs from 'node:fs';
import path from 'node:path';
import { writeFileInside } from './safe-write.mjs';

export const DEFAULT_CAPS = Object.freeze({
  gapMs: 25000, hostGapMs: 60000, perHost: 30, perDay: 100, libraryPerDay: 20, resolverPerDay: 300,
});

const day = (ms) => new Date(ms).toISOString().slice(0, 10);
const count = (v) => Number.isSafeInteger(v) && v >= 0;
const time = (v) => Number.isFinite(v) && v >= 0;
// A real calendar date (round-trips through Date) and at most one day ahead of today, so
// a clock that once ran fast cannot leave a far-future date that caps us for months.
const plausibleDate = (v, nowMs) =>
  typeof v === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(v) &&
  (() => { const d = new Date(`${v}T00:00:00Z`); return !Number.isNaN(d.getTime()) && day(d.getTime()) === v; })() &&
  v <= day(nowMs + 86400000);

export class Pacer {
  constructor({ statePath, now = Date.now, caps = {} }) {
    this.statePath = statePath;
    this.now = now;
    this.caps = { ...DEFAULT_CAPS, ...caps };
    this.state = this.#load();
  }

  #empty() {
    return { date: day(this.now()), total: 0, library: 0, hosts: new Map(), lastAny: 0, lastHost: new Map() };
  }

  // Anything unexpected in the file -> start empty (it is rewritten on the next record).
  #load() {
    try {
      const j = JSON.parse(fs.readFileSync(this.statePath, 'utf8'));
      const isObj = (o) => o !== null && typeof o === 'object' && !Array.isArray(o);
      if (!isObj(j) || !plausibleDate(j.date, this.now()) || !count(j.total) || !count(j.library) ||
          !time(j.lastAny) || !isObj(j.hosts) || !isObj(j.lastHost)) return this.#empty();
      const hosts = new Map(Object.entries(j.hosts));
      const lastHost = new Map(Object.entries(j.lastHost));
      if (![...hosts.values()].every(count) || ![...lastHost.values()].every(time)) return this.#empty();
      return { date: j.date, total: j.total, library: j.library, hosts, lastAny: j.lastAny, lastHost };
    } catch {
      return this.#empty();
    }
  }

  #rollover() {
    // Only a LATER UTC date rolls the day over: a clock stepping back keeps the counts.
    const today = day(this.now());
    if (today > this.state.date) {
      this.state.date = today;
      this.state.total = 0;
      this.state.library = 0;
      this.state.hosts = new Map();
    }
  }

  #save() {
    const s = this.state;
    const now = this.now();
    const lastHost = Object.fromEntries([...s.lastHost].filter(([, t]) => now - t < Math.max(this.caps.hostGapMs, this.caps.gapMs)));
    const out = { date: s.date, total: s.total, library: s.library, hosts: Object.fromEntries(s.hosts),
                  lastAny: s.lastAny, lastHost };
    const dir = path.dirname(this.statePath);
    fs.mkdirSync(dir, { recursive: true });
    writeFileInside(dir, path.basename(this.statePath), JSON.stringify(out));
  }

  check(host, library) {
    this.#rollover();
    if ((this.state.hosts.get(host) ?? 0) >= this.caps.perHost) return 'skipped:host-cap';
    if (this.state.total >= this.caps.perDay) return 'skipped:daily-cap';
    if (library && this.state.library >= this.caps.libraryPerDay) return 'skipped:library-cap';
    return null;
  }

  // The per-host cap alone, for a host a visit reaches after its first hop (a redirect or the
  // page's own move): 'skipped:host-cap' or null.
  hostCap(host) {
    this.#rollover();
    return (this.state.hosts.get(host) ?? 0) >= this.caps.perHost ? 'skipped:host-cap' : null;
  }

  // Count a host reached after the first hop: the per-host count and gap, not the daily total
  // (the visit was counted once, on its first hop, by record()).
  recordHost(host) {
    this.#rollover();
    this.state.hosts.set(host, (this.state.hosts.get(host) ?? 0) + 1);
    this.state.lastHost.set(host, this.now());
    this.#save();
  }

  waitMs(host) {
    const now = this.now();
    // A stored time in the future (bad clock, bad file) counts as now, and no wait ever
    // exceeds its gap.
    const left = (last, gap) => (last === undefined ? 0 : Math.min(gap, Math.max(0, gap - (now - Math.min(last, now)))));
    return Math.max(left(this.state.lastAny || undefined, this.caps.gapMs),
                    left(this.state.lastHost.get(host), this.caps.hostGapMs));
  }

  // Resolver lookups (doi.org) are paced on their own terms: a per-day cap of their own
  // (resolverPerDay, reported as the daily cap), at least gapMs between two lookups, and
  // they do not count toward the overall daily total, which counts publisher visits.
  // A lookup is pointless once the publisher daily total is reached, so that stops it too.
  checkLookup(host) {
    this.#rollover();
    if ((this.state.hosts.get(host) ?? 0) >= this.caps.resolverPerDay) return 'skipped:daily-cap';
    if (this.state.total >= this.caps.perDay) return 'skipped:daily-cap';
    return null;
  }

  lookupWaitMs(host) {
    const now = this.now();
    const last = this.state.lastHost.get(host);
    return last === undefined ? 0 : Math.min(this.caps.gapMs, Math.max(0, this.caps.gapMs - (now - Math.min(last, now))));
  }

  recordLookup(host) {
    this.#rollover();
    this.state.hosts.set(host, (this.state.hosts.get(host) ?? 0) + 1);
    this.state.lastHost.set(host, this.now());
    this.#save();
  }

  record(host, library) {
    this.#rollover();
    const now = this.now();
    this.state.total += 1;
    if (library) this.state.library += 1;
    this.state.hosts.set(host, (this.state.hosts.get(host) ?? 0) + 1);
    this.state.lastAny = now;
    this.state.lastHost.set(host, now);
    this.#save();
  }
}
