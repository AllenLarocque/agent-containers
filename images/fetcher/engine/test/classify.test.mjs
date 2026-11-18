import test from 'node:test';
import assert from 'node:assert/strict';
import { isCheck, isLoginHost, pickPdfUrl, directPdfUrl, hostOf, forbiddenHostname, forbiddenUrl } from '../lib/classify.mjs';

const cfg = { loginHosts: ['login.openathens.net', 'go.openathens.net'] };

test('challenge titles are checks', () => {
  for (const title of ['Just a moment...', 'Verify you are human', 'Are you a robot?', 'Access Denied',
                       'Checking your browser', 'Pardon Our Interruption', 'Unusual traffic from your network'])
    assert.equal(isCheck({ title, text: '' }), true, title);
});

test('a short body with a challenge phrase is a check; a long article mentioning one is not', () => {
  assert.equal(isCheck({ title: 'sciencedirect.com', text: 'Please verify you are human to continue.' }), true);
  const article = 'Results. '.repeat(300) + 'Participants were asked whether access denied them care.';
  assert.equal(isCheck({ title: 'A study of access to care', text: article }), false);
});

test('ordinary pages are not checks; missing fields are tolerated', () => {
  assert.equal(isCheck({ title: 'A study of things', text: 'Abstract. Lorem ipsum.' }), false);
  assert.equal(isCheck({}), false);
});

test('isLoginHost(host, cfg): exact names and the Duo suffix only', () => {
  assert.equal(isLoginHost('login.openathens.net', cfg), true);
  assert.equal(isLoginHost('api-1.duosecurity.com', cfg), true);
  assert.equal(isLoginHost('onlinelibrary.wiley.com', cfg), false);
  assert.equal(isLoginHost('', cfg), false);
  assert.throws(() => isLoginHost(cfg, 'login.openathens.net'), TypeError);
});

test('pickPdfUrl: citation_pdf_url first, resolved against the page', () => {
  assert.equal(pickPdfUrl({ meta: '/pdf/1', hrefs: ['https://a.org/doi/pdf/x'] }, 'https://a.org/article/1'),
    'https://a.org/pdf/1');
});

test('pickPdfUrl: then common link shapes', () => {
  const page = 'https://a.org/article/1';
  for (const h of ['https://a.org/doi/pdf/10.1/x', 'https://a.org/doi/epdf/10.1/x', 'https://a.org/doi/pdfdirect/10.1/x',
                   'https://a.org/article/1/pdf', 'https://a.org/files/paper.pdf', 'https://a.org/x.pdf?dl=1'])
    assert.equal(pickPdfUrl({ meta: '', hrefs: ['https://a.org/about', h] }, page), h, h);
  assert.equal(pickPdfUrl({ meta: '', hrefs: ['https://a.org/about', 'https://a.org/refs'] }, page), '');
});

test('pickPdfUrl: only http(s) URLs are ever returned', () => {
  const page = 'https://a.org/article/1';
  assert.equal(pickPdfUrl({ meta: 'javascript:alert(1)//x.pdf', hrefs: [] }, page), '');
  assert.equal(pickPdfUrl({ meta: '', hrefs: ['file:///etc/x.pdf', 'data:application/pdf,x.pdf'] }, page), '');
  assert.equal(pickPdfUrl({ meta: 'javascript:x', hrefs: ['https://a.org/y.pdf'] }, page), 'https://a.org/y.pdf');
});

test('directPdfUrl: Wiley pdf/epdf -> pdfdirect; other hosts unchanged', () => {
  assert.equal(directPdfUrl('https://onlinelibrary.wiley.com/doi/epdf/10.1/x'), 'https://onlinelibrary.wiley.com/doi/pdfdirect/10.1/x');
  assert.equal(directPdfUrl('https://besjournals.onlinelibrary.wiley.com/doi/pdf/10.1/x'),
    'https://besjournals.onlinelibrary.wiley.com/doi/pdfdirect/10.1/x');
  assert.equal(directPdfUrl('https://pubs.acs.org/doi/pdf/10.1/x'), 'https://pubs.acs.org/doi/pdf/10.1/x');
});

test('hostOf: lower-case host name without port; empty for anything else', () => {
  assert.equal(hostOf('https://Example.ORG:8443/a'), 'example.org');
  assert.equal(hostOf('http://127.0.0.2:5000/x'), '127.0.0.2');
  assert.equal(hostOf('about:blank'), '');
  assert.equal(hostOf('not a url'), '');
  assert.equal(hostOf('http://[::1]/'), '');
});

test('a long ordinary article containing "access denied" is not a check; a short page or the title is', () => {
  const article = 'Methods. We interviewed 412 patients about their experience of the clinic. '.repeat(40) +
    'Several reported that access denied to specialist care led to delays. ' + 'Discussion. '.repeat(50);
  assert.ok(article.length > 1500);
  assert.equal(isCheck({ title: 'Barriers to specialist care: a cohort study', text: article }), false);
  assert.equal(isCheck({ title: 'Barriers to specialist care', text: 'Access denied. You do not have permission.' }), true);
  assert.equal(isCheck({ title: 'Access Denied', text: article }), true);
});

test('forbidden hosts: loopback, private, link-local, IPv6 literals, localhost, .internal, single labels', () => {
  for (const h of ['127.0.0.1', '127.9.9.9', '10.1.2.3', '172.16.0.1', '172.31.255.255', '192.168.65.254', '169.254.169.254',
                   '100.64.0.1', '0.0.0.0', '224.0.0.1', '255.255.255.255', '[::1]', '[fe80::1]', '[::ffff:7f00:1]', 'localhost',
                   'a.localhost', 'host.docker.internal', 'metadata', '', 'LOCALHOST'])
    assert.equal(forbiddenHostname(h), true, h);
  for (const h of ['doi.org', 'onlinelibrary.wiley.com', '8.8.8.8', '172.32.0.1', '192.169.0.1', '100.128.0.1'])
    assert.equal(forbiddenHostname(h), false, h);
  // the URL parser's canonical forms are what is tested
  for (const u of ['http://2130706433/', 'http://0x7f.1/', 'http://127.1/', 'ws://localhost:3773/', 'wss://[::1]:3773/',
                   'file:///etc/passwd', 'ftp://doi.org/', 'javascript:alert(1)', 'not a url'])
    assert.equal(forbiddenUrl(u), true, u);
  assert.equal(forbiddenUrl('https://doi.org/10.5555/x'), false);
  assert.equal(forbiddenUrl('http://127.0.0.2:4000/x', new Set(['127.0.0.2:4000'])), false);
  assert.equal(forbiddenUrl('http://127.0.0.2:4001/x', new Set(['127.0.0.2:4000'])), true);
});
