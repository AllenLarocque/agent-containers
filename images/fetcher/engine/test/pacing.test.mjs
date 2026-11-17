import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { Pacer } from '../lib/pacing.mjs';

const DAY = 86400000;
const T0 = Date.UTC(2026, 10, 16, 12, 0, 0);
function setup(extra = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pace-'));
  const statePath = path.join(dir, 'sub', 'pacing.json');
  const clock = { t: T0 };
  const make = () => new Pacer({ statePath, now: () => clock.t, ...extra });
  return { dir, statePath, clock, make, p: make() };
}

test('fresh pacer allows everything and waits nothing', () => {
  const { p } = setup();
  assert.equal(p.check('a.com', false), null);
  assert.equal(p.waitMs('a.com'), 0);
});

test('30 on one host -> host-cap; other host still fine', () => {
  const { p, clock } = setup();
  for (let i = 0; i < 30; i++) { p.record('a.com', false); clock.t += 1000; }
  assert.equal(p.check('a.com', false), 'skipped:host-cap');
  assert.equal(p.check('b.com', false), null);
});

test('100 overall -> daily-cap', () => {
  const { p } = setup();
  for (let i = 0; i < 100; i++) p.record(`h${i}.com`, false);
  assert.equal(p.check('new.com', false), 'skipped:daily-cap');
});

test('20 library-routed -> library-cap only for library papers', () => {
  const { p } = setup();
  for (let i = 0; i < 20; i++) p.record(`h${i}.com`, true);
  assert.equal(p.check('x.com', true), 'skipped:library-cap');
  assert.equal(p.check('x.com', false), null);
});

test('next UTC day resets the counts', () => {
  const { p, clock } = setup();
  for (let i = 0; i < 30; i++) p.record('a.com', true);
  for (let i = 0; i < 70; i++) p.record(`h${i}.com`, false);
  assert.equal(p.check('a.com', false), 'skipped:host-cap');
  clock.t = Date.UTC(2026, 10, 17, 0, 0, 0);
  assert.equal(p.check('a.com', true), null);
  p.record('a.com', false);
  assert.equal(p.check('a.com', false), null);
});

test('the day rolls at UTC midnight, not 24 h after the first record', () => {
  const { p, clock } = setup();
  clock.t = Date.UTC(2026, 10, 16, 23, 59, 59);
  for (let i = 0; i < 30; i++) p.record('a.com', false);
  assert.equal(p.check('a.com', false), 'skipped:host-cap');
  clock.t += 1000;
  assert.equal(p.check('a.com', false), null);
});

test('waitMs: 60 s on the same host, 25 s for another, counting down', () => {
  const { p, clock } = setup();
  p.record('a.com', false);
  assert.equal(p.waitMs('a.com'), 60000);
  assert.equal(p.waitMs('b.com'), 25000);
  clock.t += 10000;
  assert.equal(p.waitMs('a.com'), 50000);
  assert.equal(p.waitMs('b.com'), 15000);
  clock.t += 100000;
  assert.equal(p.waitMs('a.com'), 0);
});

test('state persists across a new Pacer, including recent timing', () => {
  const { p, make, clock } = setup();
  for (let i = 0; i < 30; i++) p.record('a.com', true);
  const q = make();
  assert.equal(q.check('a.com', false), 'skipped:host-cap');
  assert.equal(q.waitMs('a.com'), 60000);
  clock.t += 5000;
  assert.equal(q.waitMs('b.com'), 20000);
});

test('garbage or malformed state starts at zero and is rewritten', () => {
  for (const junk of ['not json {', '', '[]', '{"counts":"x"}', 'null',
                      '{"date":"2026-11-16","total":-5,"library":0,"hosts":{},"lastAny":0,"lastHost":{}}',
                      '{"date":"2026-11-16","total":1e999,"library":0,"hosts":{},"lastAny":0,"lastHost":{}}']) {
    const { statePath, make } = setup();
    fs.mkdirSync(path.dirname(statePath), { recursive: true });
    fs.writeFileSync(statePath, junk);
    const q = make();
    assert.equal(q.check('a.com', false), null, junk);
    assert.equal(q.waitMs('a.com'), 0);
    q.record('a.com', false);
    assert.doesNotThrow(() => JSON.parse(fs.readFileSync(statePath, 'utf8')));
    assert.equal(make().waitMs('a.com'), 60000);
  }
});

test('host names that are object-prototype keys do not misbehave', () => {
  const { p } = setup();
  assert.equal(p.check('__proto__', false), null);
  p.record('__proto__', false);
  p.record('constructor', false);
  assert.equal(p.check('__proto__', false), null);
  assert.equal(p.check('toString', false), null);
});

test('state file is written atomically: no temp file left behind', () => {
  const { p, statePath } = setup();
  p.record('a.com', false);
  assert.deepEqual(fs.readdirSync(path.dirname(statePath)), ['pacing.json']);
});

test('caps are overridable', () => {
  const { p } = setup({ caps: { perHost: 2, gapMs: 1000, hostGapMs: 2000 } });
  p.record('a.com', false);
  assert.equal(p.waitMs('a.com'), 2000);
  assert.equal(p.waitMs('b.com'), 1000);
  p.record('a.com', false);
  assert.equal(p.check('a.com', false), 'skipped:host-cap');
});

// ---- fix round 1 ----
test('a stored lastAny far in the future never stalls beyond the gap', () => {
  const { statePath, make } = setup();
  fs.mkdirSync(path.dirname(statePath), { recursive: true });
  const future = T0 + 365 * DAY;
  fs.writeFileSync(statePath, JSON.stringify({ date: '2026-11-16', total: 1, library: 0, hosts: { 'a.com': 1 },
    lastAny: future, lastHost: { 'a.com': future } }));
  const q = make();
  assert.ok(q.waitMs('a.com') <= 60000);
  assert.ok(q.waitMs('b.com') <= 25000);
});

test('clock stepping back across UTC midnight keeps the day\'s counts', () => {
  const { p, clock } = setup();
  clock.t = Date.UTC(2026, 10, 17, 0, 0, 10);
  for (let i = 0; i < 30; i++) p.record('a.com', false);
  clock.t = Date.UTC(2026, 10, 16, 23, 59, 50);
  assert.equal(p.check('a.com', false), 'skipped:host-cap');
  assert.ok(p.waitMs('a.com') <= 60000);
  clock.t = Date.UTC(2026, 10, 17, 0, 1, 0);
  assert.equal(p.check('a.com', false), 'skipped:host-cap');
  clock.t = Date.UTC(2026, 10, 18, 0, 0, 1);
  assert.equal(p.check('a.com', false), null);
});
