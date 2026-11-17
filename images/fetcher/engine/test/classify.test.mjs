import test from 'node:test';
import assert from 'node:assert/strict';
import { isCheck, isLoginHost, pickPdfUrl, directPdfUrl, hostOf } from '../lib/classify.mjs';

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
