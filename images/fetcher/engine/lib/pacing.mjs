// Politeness limits, persisted so a restart does not reset them. Counts are per UTC
// day; the gaps use the last record times. `now()` returns milliseconds.
import fs from 'node:fs';
import path from 'node:path';

export const DEFAULT_CAPS = Object.freeze({
  gapMs: 25000, hostGapMs: 60000, perHost: 30, perDay: 100, libraryPerDay: 20,
});

const day = (ms) => new Date(ms).toISOString().slice(0, 10);
const count = (v) => Number.isSafeInteger(v) && v >= 0;
const time = (v) => Number.isFinite(v) && v >= 0;

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
      if (!isObj(j) || !/^\d{4}-\d{2}-\d{2}$/.test(j.date) || !count(j.total) || !count(j.library) ||
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
    const today = day(this.now());
    if (this.state.date !== today) {
      this.state.date = today;
      this.state.total = 0;
      this.state.library = 0;
      this.state.hosts = new Map();
    }
  }

  #save() {
    const s = this.state;
    const now = this.now();
    const lastHost = Object.fromEntries([...s.lastHost].filter(([, t]) => now - t < this.caps.hostGapMs));
    const out = { date: s.date, total: s.total, library: s.library, hosts: Object.fromEntries(s.hosts),
                  lastAny: s.lastAny, lastHost };
    fs.mkdirSync(path.dirname(this.statePath), { recursive: true });
    const tmp = `${this.statePath}.tmp-${process.pid}`;
    fs.writeFileSync(tmp, JSON.stringify(out));
    fs.renameSync(tmp, this.statePath);
  }

  check(host, library) {
    this.#rollover();
    if ((this.state.hosts.get(host) ?? 0) >= this.caps.perHost) return 'skipped:host-cap';
    if (this.state.total >= this.caps.perDay) return 'skipped:daily-cap';
    if (library && this.state.library >= this.caps.libraryPerDay) return 'skipped:library-cap';
    return null;
  }

  waitMs(host) {
    const now = this.now();
    const anyWait = this.state.lastAny ? this.caps.gapMs - (now - this.state.lastAny) : 0;
    const last = this.state.lastHost.get(host);
    const hostWait = last === undefined ? 0 : this.caps.hostGapMs - (now - last);
    return Math.max(0, anyWait, hostWait);
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
