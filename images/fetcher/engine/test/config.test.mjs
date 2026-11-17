import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { loadConfig, isLoginHost } from '../lib/config.mjs';

function cfgFile(text) {
  const p = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'cfg-')), 'fetcher.conf');
  if (text !== null) fs.writeFileSync(p, text);
  return p;
}

test('defaults', () => {
  const c = loadConfig(cfgFile(''));
  assert.equal(c.resolver, 'https://doi.org/');
  assert.equal(c.libraryPrefix, '');
  assert.deepEqual(c.loginHosts, ['login.openathens.net', 'go.openathens.net']);
  assert.deepEqual(c.caps, { gapMs: 25000, hostGapMs: 60000, perHost: 30, perDay: 100, libraryPerDay: 20 });
});

test('a missing file gives the defaults', () => {
  assert.equal(loadConfig(cfgFile(null)).resolver, 'https://doi.org/');
});

test('values are read; comments and blank lines are ignored', () => {
  const c = loadConfig(cfgFile([
    '# comment', '', 'LIBRARY_PREFIX=https://go.openathens.net/redirector/example.ac.uk?url=',
    'LOGIN_HOSTS=sso.example.ac.uk, idp.example.org', 'GAP_MS=1000', 'HOST_GAP_MS=2000', 'PER_HOST=3', 'PER_DAY=4',
    'LIBRARY_PER_DAY=5', 'RESOLVER=https://dx.doi.org/'].join('\n')));
  assert.equal(c.libraryPrefix, 'https://go.openathens.net/redirector/example.ac.uk?url=');
  assert.deepEqual(c.loginHosts, ['login.openathens.net', 'go.openathens.net', 'sso.example.ac.uk', 'idp.example.org']);
  assert.deepEqual(c.caps, { gapMs: 1000, hostGapMs: 2000, perHost: 3, perDay: 4, libraryPerDay: 5 });
  assert.equal(c.resolver, 'https://dx.doi.org/');
});

test('login hosts match by exact name or .duosecurity.com suffix', () => {
  const c = loadConfig(cfgFile(''));
  for (const h of ['login.openathens.net', 'go.openathens.net', 'api-1234.duosecurity.com', 'x.y.duosecurity.com'])
    assert.equal(isLoginHost(c, h), true, h);
  for (const h of ['duosecurity.com', 'evilduosecurity.com', 'duosecurity.com.evil.net', 'openathens.net', 'wiley.com', ''])
    assert.equal(isLoginHost(c, h), false, h);
});

test('unknown keys, duplicates and malformed lines are rejected', () => {
  for (const t of ['BOGUS=1', 'PER_DAY=5\nPER_DAY=6', 'no equals sign', '=x', 'per_day=5', 'PER_DAY=abc', 'PER_DAY=-1',
                   'PER_DAY=1.5', 'GAP_MS=', 'RESOLVER=http://doi.org/', 'RESOLVER=https://doi.org', 'RESOLVER=https://a b/',
                   'LIBRARY_PREFIX=http://insecure/', 'LIBRARY_PREFIX=javascript:alert(1)', 'LOGIN_HOSTS=A.B', 'LOGIN_HOSTS=a b',
                   'LOGIN_HOSTS=.duosecurity.com/x'])
    assert.throws(() => loadConfig(cfgFile(t)), Error, JSON.stringify(t));
});

test('loadConfig does not mutate shared defaults between calls', () => {
  const a = loadConfig(cfgFile('LOGIN_HOSTS=x.example.org'));
  const b = loadConfig(cfgFile(''));
  assert.deepEqual(b.loginHosts, ['login.openathens.net', 'go.openathens.net']);
  assert.equal(a.loginHosts.length, 3);
});

// ---- fix round 1 ----
test('load errors never contain a configured value', () => {
  for (const t of ['LIBRARY_PREFIX=https://secret-uni.example.ac.uk/r?token=abc\nBOGUS=1',
                   'LIBRARY_PREFIX=http://secret-uni.example.ac.uk/r',
                   'LOGIN_HOSTS=SECRET-UNI.example',
                   'PER_DAY=secret-uni']) {
    assert.throws(() => loadConfig(cfgFile(t)), (e) => !/secret-uni|token=abc/.test(e.message), t);
  }
});

test('isLoginHost: case-insensitive, strict', () => {
  const c = loadConfig(cfgFile(''));
  for (const h of ['api-1234.duosecurity.com', 'API-1234.DUOSECURITY.COM', 'Go.OpenAthens.Net']) assert.equal(isLoginHost(c, h), true, h);
  for (const h of ['evilduosecurity.com', 'duosecurity.com.evil.net', 'a..duosecurity.com', '-', 'x y.duosecurity.com', 'a.duosecurity.com\n'])
    assert.equal(isLoginHost(c, h), false, h);
  assert.equal(isLoginHost({ loginHosts: ['-'] }, '-'), false);
});

test('timeouts: defaults 60 s / 9 s / 45 s, overridable', () => {
  assert.deepEqual(loadConfig(cfgFile('')).timeouts, { navMs: 60000, settleMs: 9000, downloadMs: 45000 });
  const c = loadConfig(cfgFile('NAV_TIMEOUT_MS=3000\nSETTLE_MS=300\nDOWNLOAD_TIMEOUT_MS=4000\n'));
  assert.deepEqual(c.timeouts, { navMs: 3000, settleMs: 300, downloadMs: 4000 });
  assert.throws(() => loadConfig(cfgFile('SETTLE_MS=9s\n')), /line 1/);
});
