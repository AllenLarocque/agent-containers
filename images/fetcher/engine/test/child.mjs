// Test-only entry point: runs the real loop in its own process so tests can capture its
// stdout/stderr and kill it. Takes a JSON file with the paths and a config object (the
// fixture server is plain http on loopback, which the production config file refuses, and the
// browser's loopback guard lets the fixture's hosts through only by testOnlyAllow, which only a
// caller's options can set).
import fs from 'node:fs';
import { runLoop } from '../fetcher.mjs';

const o = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
await runLoop({ ...o, sandbox: process.env.FETCHER_TEST_SANDBOX !== 'off' });
