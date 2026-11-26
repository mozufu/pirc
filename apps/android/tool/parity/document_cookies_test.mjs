import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createContext, runInContext} from 'node:vm';
import {Buffer} from 'node:buffer';
import {test} from 'node:test';
import {fileURLToPath} from 'node:url';
import path from 'node:path';

const sourcePath = fileURLToPath(new URL('./document_cookies_source.js', import.meta.url));
const fixturePath = fileURLToPath(new URL('../../../../packages/pirc_render/test/fixtures/parity/document-cookies-chrome155.json', import.meta.url));
const [source, fixtureText] = await Promise.all([
  readFile(sourcePath, 'utf8'),
  readFile(fixturePath, 'utf8'),
]);
const chrome = JSON.parse(fixtureText);
const responseCase = chrome.cases.find(item => item.caseId === 'response-set-cookie-redirect');
const scriptCase = chrome.cases.find(item => item.caseId === 'script-cookie-api');
assert.ok(responseCase && scriptCase, 'Frozen Chrome fixture must contain cookie seed and script observations.');

function splitCookieString(value) {
  return new Map(String(value).split(/;\s*/).filter(Boolean).map(pair => {
    const equals = pair.indexOf('=');
    return [pair.slice(0, equals), pair.slice(equals + 1)];
  }));
}

function parseSetCookie(line) {
  const [pair, ...rawAttributes] = line.split(';');
  const equals = pair.indexOf('=');
  const attributes = new Map();
  for (const raw of rawAttributes) {
    const index = raw.indexOf('=');
    const name = (index < 0 ? raw : raw.slice(0, index)).trim().toLowerCase();
    const value = index < 0 ? '' : raw.slice(index + 1).trim();
    attributes.set(name, value);
  }
  return {name: pair.slice(0, equals).trim(), value: pair.slice(equals + 1).trim(), attributes};
}

function makeChromeSeed(now = Date.now()) {
  const visible = splitCookieString(responseCase.document.documentCookie);
  const storage = new Map(responseCase.cookieStorage.cookies.map(cookie => [cookie.name, cookie]));
  const documentUrl = new URL(responseCase.document.href);
  const cookies = [];
  const protections = [];
  let creationOrder = 0;

  for (const line of responseCase.sourceResponseSetCookie) {
    const parsed = parseSetCookie(line);
    const metadata = storage.get(parsed.name);
    const isVisible = visible.get(parsed.name) === parsed.value;
    if (!isVisible && !metadata) continue;
    const domainAttribute = parsed.attributes.get('domain');
    const pathAttribute = parsed.attributes.get('path');
    const cookiePath = pathAttribute?.startsWith('/') ? pathAttribute : (() => {
      const slash = documentUrl.pathname.lastIndexOf('/');
      return slash <= 0 ? '/' : documentUrl.pathname.slice(0, slash);
    })();
    const domain = domainAttribute?.replace(/^\./, '').toLowerCase() ?? documentUrl.hostname;
    const hostOnly = domainAttribute == null;
    const secure = parsed.attributes.has('secure');
    const httpOnly = parsed.attributes.has('httponly');
    const sameSiteValue = parsed.attributes.get('samesite')?.toLowerCase();
    const sameSite = ['strict', 'lax', 'none'].includes(sameSiteValue) ? sameSiteValue : 'default';
    const maxAgeText = parsed.attributes.get('max-age');
    const maxAge = maxAgeText != null && /^-?\d+$/.test(maxAgeText) ? Number(maxAgeText) : null;
    const expiresText = parsed.attributes.get('expires');
    const expiresAt = maxAge != null ? (maxAge <= 0 ? 0 : now + maxAge * 1000) :
      (expiresText ? Date.parse(expiresText) : null);
    creationOrder++;

    if (httpOnly) {
      if (metadata?.httpOnly) {
        protections.push({
          name: parsed.name,
          domain,
          path: cookiePath,
          hostOnly,
          secure,
          httpOnly: true,
        });
      }
      continue;
    }
    if (!isVisible) continue;
    cookies.push({
      name: parsed.name,
      value: parsed.value,
      domain,
      path: cookiePath,
      hostOnly,
      secure,
      sameSite,
      expiresAt,
      createdAt: now,
      creationOrder,
      hasHostPrefixPathAttribute: parsed.attributes.has('path') && cookiePath === '/',
    });
    if (secure) {
      protections.push({name: parsed.name, domain, path: cookiePath, hostOnly, secure: true, httpOnly: false});
    }
  }

  return {
    generation: 47,
    revision: 9,
    url: documentUrl.href,
    secureOrigin: true,
    sameSiteContext: true,
    cookies,
    protections,
    allowedDomainSuffixes: [documentUrl.hostname],
    truncated: false,
  };
}

function createHarness(options = {}) {
  const now = options.now ?? Date.now();
  const seed = options.seed ?? makeChromeSeed(now);
  let activeUrl = options.initialUrl ?? seed.url;
  let clock = now;
  class ControlledDate extends Date {
    static now() { return clock; }
  }
  const sandbox = createContext({
    Date: ControlledDate,
    pircUrlPolyfill: {URL},
  });
  runInContext(source + '\n;globalThis.__createCookieHelper = createPircDocumentCookies;', sandbox, {
    filename: sourcePath,
  });
  const diagnostics = [];
  const helper = sandbox.__createCookieHelper({
    getUrl: () => activeUrl,
    utf8ByteLength: value => Buffer.byteLength(String(value), 'utf8'),
    diagnostic: (...args) => diagnostics.push(args),
  });
  const document = {};
  helper.install(document, seed);
  return {
    document,
    helper,
    diagnostics,
    seed,
    setUrl(value) { activeUrl = value; },
    advance(ms) { clock += ms; },
    currentUrl() { return activeUrl; },
  };
}

test('hydrates the current native state schema and matches Chrome document.cookie at initial load', () => {
  const harness = createHarness();
  assert.equal(harness.document.cookie, responseCase.document.documentCookie);
  assert.ok(harness.seed.cookies.every(cookie => 'hostOnly' in cookie && 'expiresAt' in cookie));
  assert.ok(harness.seed.protections.every(cookie => !Object.hasOwn(cookie, 'value')));
});

test('setter updates getter synchronously and preserves write order and URL for native flush', () => {
  const harness = createHarness();
  const first = 'sequence=a; Path=/; SameSite=Lax';
  const second = 'sequence=b; Path=/; SameSite=Lax';
  harness.document.cookie = first;
  assert.match(harness.document.cookie, /(?:^|; )sequence=a(?:; |$)/);
  harness.document.cookie = second;
  assert.match(harness.document.cookie, /(?:^|; )sequence=b(?:; |$)/);
  assert.doesNotMatch(harness.document.cookie, /(?:^|; )sequence=a=/);

  const writes = harness.helper.drain();
  assert.deepEqual(JSON.parse(JSON.stringify(writes)), [
    {url: responseCase.document.href, line: first, generation: harness.seed.generation},
    {url: responseCase.document.href, line: second, generation: harness.seed.generation},
  ]);
  assert.ok(writes.every(write => !Object.hasOwn(write, 'authorization') && !Object.hasOwn(write, 'headers')));

  const browserRequests = chrome.serverRequests.filter(item =>
    item.caseId === 'same-turn-cookie-a' || item.caseId === 'same-turn-cookie-b',
  );
  assert.equal(browserRequests.length, 2);
  assert.ok(browserRequests.every(item => item.cookie?.includes('sequence=b')));
  assert.ok(browserRequests.every(item => !item.cookie?.includes('sequence=a')));
});

test('HttpOnly values stay out of the JS seed and block overwrite and removal', () => {
  const harness = createHarness();
  assert.ok(harness.seed.protections.some(cookie => cookie.name === 'a_http' && cookie.httpOnly));
  assert.ok(harness.seed.protections.every(cookie => !Object.hasOwn(cookie, 'value')));
  assert.doesNotMatch(harness.document.cookie, /a_http|secret/);

  harness.document.cookie = 'a_http=overwritten; Path=/; SameSite=Lax';
  assert.doesNotMatch(harness.document.cookie, /a_http|overwritten|secret/);
  harness.document.cookie = 'a_http=; Path=/; Max-Age=0';
  assert.doesNotMatch(harness.document.cookie, /a_http|secret/);
  assert.equal(harness.helper.drain().length, 2, 'Native still receives the attempted lines to validate independently.');
});

test('prefix checks, lowercase Chrome controls, and HttpOnly script limits stay visible', () => {
  const harness = createHarness();
  assert.match(harness.document.cookie, /__Secure-http-secure=bad/);
  assert.match(harness.document.cookie, /__Host-valid=accepted/);
  assert.match(harness.document.cookie, /__host-lowercase-valid=accepted/);
  assert.match(harness.document.cookie, /__secure-lowercase-valid=accepted/);
  assert.doesNotMatch(harness.document.cookie, /__Http-valid|__Host-Http-valid/);

  harness.document.cookie = '__Secure-rejected=x; Path=/';
  assert.doesNotMatch(harness.document.cookie, /__Secure-rejected/);
  harness.document.cookie = '__Secure-accepted=x; Path=/; Secure';
  assert.match(harness.document.cookie, /__Secure-accepted=x/);
  harness.document.cookie = '__Host-no-path=x; Secure';
  assert.doesNotMatch(harness.document.cookie, /__Host-no-path/);
  harness.document.cookie = '__Host-accepted=x; Path=/; Secure';
  assert.match(harness.document.cookie, /__Host-accepted=x/);
  harness.document.cookie = '__Http-script=x; Path=/; Secure';
  harness.document.cookie = '__Host-Http-script=x; Path=/; Secure; HttpOnly';
  assert.doesNotMatch(harness.document.cookie, /__Http-script|__Host-Http-script/);

  const chromeHostDomain = scriptCase.scriptOperations.results.find(item => item.label === 'host-prefix-with-domain');
  assert.ok(chromeHostDomain.visibleImmediately.includes('__Host-script=bad'));
  harness.document.cookie = chromeHostDomain.assignment;
  assert.doesNotMatch(harness.document.cookie, /__Host-script=bad/);
  assert.match(chromeHostDomain.assignment, /Domain=127\.0\.0\.1/);
});

test('Max-Age takes precedence, expires cookies at the boundary, and leaves session cookies live', () => {
  const now = 1_800_000_000_000;
  const harness = createHarness({now});
  assert.match(harness.document.cookie, /a_persistent=persistent/);
  harness.document.cookie = 'max_age_wins=live; Path=/; Max-Age=3600; Expires=Thu, 01 Jan 1970 00:00:00 GMT';
  assert.match(harness.document.cookie, /max_age_wins=live/);
  harness.document.cookie = 'remove_now=yes; Path=/; Max-Age=0';
  assert.doesNotMatch(harness.document.cookie, /remove_now/);

  harness.advance(3_600_001);
  assert.doesNotMatch(harness.document.cookie, /a_persistent=persistent|script_persistent/);
  assert.match(harness.document.cookie, /a_session=session/);
  assert.doesNotMatch(harness.document.cookie, /max_age_wins=live/);
});

test('pushState retains the creation URL for document.cookie paths and native write URLs', () => {
  const harness = createHarness();
  const outsideHistoryUrl = scriptCase.scriptOperations.historyPathSnapshots.find(item =>
    item.label === 'outside-after-pushState',
  );
  assert.ok(outsideHistoryUrl);
  harness.setUrl(outsideHistoryUrl.href);
  assert.equal(harness.document.cookie, responseCase.document.documentCookie);

  harness.document.cookie = 'pushstate_default=outside-default';
  assert.match(harness.document.cookie, /pushstate_default=outside-default/);
  harness.document.cookie = 'pushstate_explicit=outside-explicit; Path=/outside; SameSite=Lax';
  assert.doesNotMatch(harness.document.cookie, /pushstate_explicit/);
  const writes = harness.helper.drain();
  assert.deepEqual(JSON.parse(JSON.stringify(writes)).map(write => write.url),
    [responseCase.document.href, responseCase.document.href]);

  const updatedSeed = structuredClone(harness.seed);
  updatedSeed.url = outsideHistoryUrl.href;
  updatedSeed.cookies.push(
    {name: 'pushstate_default', value: 'outside-default', domain: '127.0.0.1', hostOnly: true,
      path: '/nested', secure: false, sameSite: 'default', expiresAt: null, createdAt: 1, creationOrder: 100},
    {name: 'pushstate_explicit', value: 'outside-explicit', domain: '127.0.0.1', hostOnly: true,
      path: '/outside', secure: false, sameSite: 'lax', expiresAt: null, createdAt: 1, creationOrder: 101},
  );
  harness.helper.sync(updatedSeed);
  assert.match(harness.document.cookie, /pushstate_default=outside-default/);
  assert.doesNotMatch(harness.document.cookie, /pushstate_explicit/);

  const nestedRequest = scriptCase.scriptOperations.nestedPathRequestAfterPushState;
  const outsideRequest = scriptCase.scriptOperations.outsidePathRequest;
  assert.ok(nestedRequest.cookie.includes('pushstate_default=outside-default'));
  assert.ok(nestedRequest.cookie.includes('a_path=path'));
  assert.ok(!nestedRequest.cookie.includes('pushstate_explicit=outside-explicit'));
  assert.ok(outsideRequest.cookie.includes('pushstate_explicit=outside-explicit'));
  assert.ok(!outsideRequest.cookie.includes('pushstate_default=outside-default'));
  assert.ok(!outsideRequest.cookie.includes('a_path=path'));
});

test('frozen request observations keep credentials separate and page traffic loopback-only', () => {
  assert.ok(chrome.serverRequests.length >= 40);
  assert.ok(chrome.serverRequests.every(item => item.authorization == null && item.authorizationPresent === false));
  assert.equal(chrome.externalProxy.forwardsRequests, false);
  assert.equal(chrome.externalProxy.pageRequestsStayedOnSyntheticLoopbackHosts, true);
  assert.deepEqual(chrome.externalProxy.unexpectedPageRequests, []);

  const omitted = chrome.serverRequests.find(item => item.caseId === 'fetch-same-origin-omit');
  const included = chrome.serverRequests.find(item => item.caseId === 'fetch-same-origin-include');
  assert.equal(omitted.cookie, null);
  assert.ok(included.cookie?.includes('a_session=session'));
});
