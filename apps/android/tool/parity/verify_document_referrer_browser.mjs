import { requireTestBrowserExecutable } from './test_browser.mjs';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {existsSync, readFileSync} from 'node:fs';
import {writeFile} from 'node:fs/promises';
import path from 'node:path';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(scriptDirectory, '../../../..');
const require = createRequire(import.meta.url);
const {chromium} = require(require.resolve('playwright-core', {
  paths: [path.join(repositoryRoot, 'apps/gateway')],
}));
const browserExecutable = requireTestBrowserExecutable();
assert.ok(existsSync(browserExecutable), 'The installed Google Chrome executable was not found.');
const runnerSource = readFileSync(fileURLToPath(import.meta.url), 'utf8');

const policies = [
  'no-referrer',
  'no-referrer-when-downgrade',
  'origin',
  'origin-when-cross-origin',
  'same-origin',
  'strict-origin',
  'strict-origin-when-cross-origin',
  'unsafe-url',
];
const cases = [];
for (const policy of policies) {
  for (const destination of ['same', 'cross']) {
    cases.push({
      caseId: 'lower-' + policy + '-' + destination,
      group: 'policy-lowercase',
      policy,
      destination,
      elementPolicy: policy,
      // If the element value were rejected, this opposite policy would be visible.
      headerPolicy: policy === 'no-referrer' ? 'unsafe-url' : 'no-referrer',
    });
  }
  if (policy === 'origin') {
    cases.push({
      caseId: 'uppercase-header-origin',
      group: 'header-uppercase',
      policy: policy.toUpperCase(),
      destination: 'same',
      headerPolicy: policy.toUpperCase(),
    });
  } else {
    cases.push({
      caseId: 'uppercase-' + policy,
      group: 'policy-uppercase',
      policy: policy.toUpperCase(),
      destination: 'same',
      elementPolicy: policy.toUpperCase(),
      headerPolicy: policy === 'no-referrer' ? 'unsafe-url' : 'no-referrer',
    });
  }
}
cases.push(
  {
    caseId: 'rel-noreferrer',
    group: 'rel-override',
    destination: 'same',
    headerPolicy: 'unsafe-url',
    elementPolicy: 'unsafe-url',
    rel: 'noreferrer',
  },
  {
    caseId: 'header-meta-priority',
    group: 'policy-source-priority',
    destination: 'cross',
    headerPolicy: 'unsafe-url',
    metaPolicy: 'no-referrer',
  },
  {
    caseId: 'element-policy-and-redirect-tightening',
    group: 'policy-source-priority-and-redirect',
    destination: 'redirect-tighten',
    headerPolicy: 'no-referrer',
    metaPolicy: 'origin',
    elementPolicy: 'unsafe-url',
  },
  {
    caseId: 'redirect-cross-to-same',
    group: 'redirect-chain',
    destination: 'redirect-cross-to-same',
    elementPolicy: 'strict-origin-when-cross-origin',
  },
  {
    caseId: 'source-url-over-4096',
    group: 'url-sanitization',
    destination: 'same',
    elementPolicy: 'unsafe-url',
    headerPolicy: 'no-referrer',
    longSource: true,
  },
  {
    caseId: 'source-credentials-and-fragment',
    group: 'url-sanitization',
    destination: 'same',
    elementPolicy: 'unsafe-url',
    headerPolicy: 'no-referrer',
    credentialsAndFragment: true,
  },
);
assert.equal(cases.length, 30, 'Keep this oracle at the agreed 30-case limit.');
const casesById = new Map(cases.map(item => [item.caseId, item]));
const requests = [];
const blockedRequests = [];
let sameOrigin = '';
let crossOrigin = '';
const fixtureSameOrigin = 'http://127.0.0.1:43178';
const fixtureCrossOrigin = 'http://127.0.0.1:43179';

function htmlResponse(response, body, extraHeaders = {}) {
  response.writeHead(200, {
    'content-type': 'text/html; charset=utf-8',
    'cache-control': 'no-store',
    ...extraHeaders,
  });
  response.end(body);
}

function sourceUrlFor(spec) {
  const url = new URL('/source', sameOrigin);
  url.searchParams.set('case', spec.caseId);
  if (spec.longSource) url.searchParams.set('pad', 'x'.repeat(4200));
  if (spec.credentialsAndFragment) {
    url.username = 'oracle-user';
    url.password = 'oracle-pass';
    url.hash = 'private-fragment';
  }
  return url;
}

function targetUrlFor(spec) {
  let targetOrigin = sameOrigin;
  let targetPath = '/target';
  if (spec.destination === 'cross') targetOrigin = crossOrigin;
  if (spec.destination === 'redirect-tighten') {
    targetOrigin = crossOrigin;
    targetPath = '/redirect/tighten';
  }
  if (spec.destination === 'redirect-cross-to-same') {
    targetOrigin = crossOrigin;
    targetPath = '/redirect/cross-to-same';
  }
  const target = new URL(targetPath, targetOrigin);
  target.searchParams.set('case', spec.caseId);
  return target.href;
}

function sourceHtml(spec) {
  const meta = spec.metaPolicy
    ? '<meta name="referrer" content="' + spec.metaPolicy + '">'
    : '';
  const rel = spec.rel ? ' rel="' + spec.rel + '"' : '';
  const elementPolicy = spec.elementPolicy
    ? ' referrerpolicy="' + spec.elementPolicy + '"'
    : '';
  return '<!doctype html><html><head><meta charset="utf-8">' + meta +
    '<title>Referrer source</title></head><body>' +
    '<a id="navigate" href="' + targetUrlFor(spec) + '"' + rel +
    elementPolicy + '>Navigate</a></body></html>';
}

const destinationHtml = '<!doctype html><html><head><meta charset="utf-8">' +
  '<title>Referrer destination</title></head><body>Destination</body></html>';

function makeServer(serverName) {
  return createServer((request, response) => {
    const serverOrigin = serverName === 'same' ? sameOrigin : crossOrigin;
    const requestUrl = new URL(request.url ?? '/', serverOrigin || 'http://127.0.0.1');
    const caseId = requestUrl.searchParams.get('case') ?? '';
    const requestSpec = casesById.get(caseId);
    const responseReferrerPolicy = requestUrl.pathname === '/source'
      ? requestSpec?.headerPolicy ?? null
      : requestUrl.pathname === '/redirect/tighten'
        ? 'origin'
        : null;
    requests.push({
      server: serverName,
      method: request.method ?? '',
      url: requestUrl.href,
      path: requestUrl.pathname,
      caseId,
      queryLength: requestUrl.search.length,
      referer: request.headers.referer ?? '',
      responseReferrerPolicy,
      authorizationPresent: Boolean(request.headers.authorization),
    });

    if (request.method === 'GET' && requestUrl.pathname === '/favicon.ico') {
      response.writeHead(204);
      response.end();
      return;
    }
    if (request.method === 'GET' && requestUrl.pathname === '/source') {
      const spec = casesById.get(caseId);
      if (!spec || serverName !== 'same') {
        response.writeHead(404);
        response.end('unknown local oracle case');
        return;
      }
      const headers = {};
      if (spec.headerPolicy) headers['referrer-policy'] = spec.headerPolicy;
      htmlResponse(response, sourceHtml(spec), headers);
      return;
    }
    if (request.method === 'GET' && requestUrl.pathname === '/redirect/tighten' &&
        serverName === 'cross' && caseId === 'element-policy-and-redirect-tightening') {
      response.writeHead(302, {
        'cache-control': 'no-store',
        'location': sameOrigin + '/final?case=' + encodeURIComponent(caseId),
        'referrer-policy': 'origin',
      });
      response.end();
      return;
    }
    if (request.method === 'GET' && requestUrl.pathname === '/redirect/cross-to-same' &&
        serverName === 'cross' && caseId === 'redirect-cross-to-same') {
      response.writeHead(302, {
        'cache-control': 'no-store',
        'location': sameOrigin + '/final?case=' + encodeURIComponent(caseId),
      });
      response.end();
      return;
    }
    if (request.method === 'GET' &&
        (requestUrl.pathname === '/target' || requestUrl.pathname === '/final')) {
      htmlResponse(response, destinationHtml);
      return;
    }
    response.writeHead(404, {'content-type': 'text/plain; charset=utf-8'});
    response.end('unknown local oracle path');
  });
}

const sameServer = makeServer('same');
const crossServer = makeServer('cross');
async function listen(server) {
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const address = server.address();
  assert.ok(address && typeof address === 'object');
  return 'http://127.0.0.1:' + address.port;
}
async function closeServer(server) {
  if (!server.listening) return;
  await new Promise(resolve => server.close(resolve));
}

function expectedPolicyReferer(policy, source, target) {
  const cleanSource = new URL(source);
  cleanSource.username = '';
  cleanSource.password = '';
  cleanSource.hash = '';
  const full = cleanSource.href;
  const origin = cleanSource.origin + '/';
  const same = cleanSource.origin === new URL(target).origin;
  switch (policy.toLowerCase()) {
    case 'no-referrer':
      return '';
    case 'no-referrer-when-downgrade':
      return full;
    case 'origin':
      return origin;
    case 'origin-when-cross-origin':
      return same ? full : origin;
    case 'same-origin':
      return same ? full : '';
    case 'strict-origin':
      return origin;
    case 'strict-origin-when-cross-origin':
      return same ? full : origin;
    case 'unsafe-url':
      return full;
    default:
      throw new Error('Unknown referrer policy: ' + policy);
  }
}

function normalizeOrigins(value) {
  const samePort = new URL(sameOrigin).port;
  const crossPort = new URL(crossOrigin).port;
  return value
    .replaceAll(sameOrigin, fixtureSameOrigin)
    .replaceAll(crossOrigin, fixtureCrossOrigin)
    .replaceAll('@127.0.0.1:' + samePort, '@127.0.0.1:' + new URL(fixtureSameOrigin).port)
    .replaceAll('@127.0.0.1:' + crossPort, '@127.0.0.1:' + new URL(fixtureCrossOrigin).port);
}

function normalizeFixtureValue(value) {
  if (typeof value === 'string') return normalizeOrigins(value);
  if (Array.isArray(value)) return value.map(normalizeFixtureValue);
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value).map(([key, item]) => [key, normalizeFixtureValue(item)]),
    );
  }
  return value;
}

let browser = null;
try {
  sameOrigin = await listen(sameServer);
  crossOrigin = await listen(crossServer);
  assert.notEqual(sameOrigin, crossOrigin, 'The two loopback listeners must be cross-origin.');
  browser = await chromium.launch({
    headless: true,
    executablePath: browserExecutable,
    args: ['--disable-gpu'],
  });

  const results = [];
  for (const spec of cases) {
    const requestStart = requests.length;
    const context = await browser.newContext();
    context.route('**/*', async route => {
      const requestUrl = new URL(route.request().url());
      const allowed = requestUrl.protocol === 'http:' &&
        requestUrl.hostname === '127.0.0.1' &&
        [new URL(sameOrigin).port, new URL(crossOrigin).port].includes(requestUrl.port);
      if (allowed) {
        await route.continue();
      } else {
        blockedRequests.push(requestUrl.href);
        await route.abort();
      }
    });
    const page = await context.newPage();
    try {
      const sourceUrl = sourceUrlFor(spec);
      await page.goto(sourceUrl.href, {waitUntil: 'domcontentloaded'});
      const sourceDocument = await page.evaluate(() => {
        const url = new URL(location.href);
        return {
          urlLength: location.href.length,
          hasCredentials: Boolean(url.username || url.password),
          hasFragment: Boolean(url.hash),
          pathname: url.pathname,
        };
      });
      const navigation = page.waitForNavigation({
        waitUntil: 'domcontentloaded',
        timeout: 10000,
      });
      await page.locator('#navigate').click();
      await navigation;
      const finalDocument = await page.evaluate(() => ({
        url: location.href,
        pathname: location.pathname,
        documentReferrer: document.referrer,
      }));
      const caseRequests = requests.slice(requestStart);
      const requestHops = caseRequests
        .filter(item => item.path !== '/source')
        .map((item, index, hops) => ({
          hop: index + 1,
          server: item.server,
          method: item.method,
          url: item.url,
          path: item.path,
          referer: item.referer,
          responseReferrerPolicy: item.responseReferrerPolicy,
          documentReferrer: index === hops.length - 1
            ? finalDocument.documentReferrer
            : null,
        }));
      results.push({
        caseId: spec.caseId,
        group: spec.group,
        policy: spec.policy ?? null,
        headerPolicy: spec.headerPolicy ?? null,
        metaPolicy: spec.metaPolicy ?? null,
        elementPolicy: spec.elementPolicy ?? null,
        rel: spec.rel ?? null,
        sourceUrl: sourceUrl.href,
        targetUrl: targetUrlFor(spec),
        sourceDocument,
        sourceUrlInput: {
          hasCredentials: Boolean(sourceUrl.username || sourceUrl.password),
          hasFragment: Boolean(sourceUrl.hash),
        },
        finalDocument,
        requestHops,
        requests: caseRequests,
      });
    } finally {
      await context.close();
    }
  }

  assert.deepEqual(blockedRequests, [], 'The browser attempted to reach a non-oracle origin.');
  assert.equal(results.length, 30);
  const resultById = new Map(results.map(item => [item.caseId, item]));
  for (const spec of cases.filter(item => item.group === 'policy-lowercase' ||
      item.group === 'policy-uppercase')) {
    const result = resultById.get(spec.caseId);
    const source = sourceUrlFor(spec);
    const target = targetUrlFor(spec);
    const expected = expectedPolicyReferer(
      spec.elementPolicy ?? spec.headerPolicy,
      source.href,
      target,
    );
    const navigationRequests = result.requests.filter(item => item.path !== '/source');
    assert.equal(navigationRequests.length, 1, spec.caseId + ' should perform one destination request.');
    assert.equal(navigationRequests[0].referer, expected, spec.caseId + ' Referer header mismatch.');
    assert.equal(result.finalDocument.documentReferrer, expected,
      spec.caseId + ' document.referrer mismatch.');
  }

  const noreferrer = resultById.get('rel-noreferrer');
  assert.equal(noreferrer.requests.at(-1)?.referer, '', 'rel=noreferrer must suppress Referer.');
  assert.equal(noreferrer.finalDocument.documentReferrer, '',
    'rel=noreferrer must suppress document.referrer.');

  const headerMeta = resultById.get('header-meta-priority');
  const headerMetaReferer = headerMeta.requests.at(-1)?.referer ?? '';
  const headerMetaSource = sourceUrlFor(casesById.get('header-meta-priority'));
  const headerMetaFull = new URL(headerMetaSource);
  headerMetaFull.hash = '';
  const headerMetaPriority = headerMetaReferer === headerMetaFull.href
    ? 'response-header-overrides-meta'
    : headerMetaReferer === ''
      ? 'meta-overrides-response-header'
      : 'unexpected-value';

  const headerUppercase = resultById.get('uppercase-header-origin');
  const headerUppercaseReferer = headerUppercase.requests.at(-1)?.referer ?? '';
  const headerUppercaseOrigin = new URL(sameOrigin).origin + '/';
  const headerUppercaseSource = sourceUrlFor(casesById.get('uppercase-header-origin')).href;
  const headerCaseSensitivity = headerUppercaseReferer === headerUppercaseOrigin
    ? 'case-insensitive'
    : headerUppercaseReferer === headerUppercaseSource
      ? 'case-sensitive-or-ignored'
      : 'unexpected-value';
  assert.ok(
    headerCaseSensitivity === 'case-insensitive' ||
      headerCaseSensitivity === 'case-sensitive-or-ignored',
    'The uppercase response header should produce a known Referrer-Policy result.',
  );
  assert.equal(headerUppercase.finalDocument.documentReferrer, headerUppercaseReferer,
    'The uppercase header case should match its final document.referrer.');

  const elementRedirect = resultById.get('element-policy-and-redirect-tightening');
  const elementRedirectNavigation = elementRedirect.requests.filter(item => item.path !== '/source');
  const redirectOrigin = new URL(sameOrigin).origin + '/';
  assert.equal(elementRedirectNavigation[0]?.referer,
    expectedPolicyReferer('unsafe-url', sourceUrlFor(casesById.get(
      'element-policy-and-redirect-tightening')).href,
    targetUrlFor(casesById.get('element-policy-and-redirect-tightening'))),
    'Element referrerpolicy should take precedence over both source policies.');
  assert.equal(elementRedirectNavigation.at(-1)?.referer, redirectOrigin,
    'The redirect response Referrer-Policy: origin should remove the source path.');

  const crossToSame = resultById.get('redirect-cross-to-same');
  const crossToSameNavigation = crossToSame.requests.filter(item => item.path !== '/source');
  assert.equal(crossToSameNavigation.length, 2,
    'The cross-origin to same-origin redirect should produce two destination requests.');
  assert.equal(crossToSameNavigation[0]?.referer, new URL(sameOrigin).origin + '/',
    'The first cross-origin hop should receive only the source origin.');
  assert.equal(crossToSameNavigation[1]?.referer, new URL(sameOrigin).origin + '/',
    'Returning to the source origin must not restore the source path after a cross-origin hop.');

  const longSource = resultById.get('source-url-over-4096');
  assert.ok(longSource.sourceDocument.urlLength > 4096,
    'The long source document URL must exceed 4096 characters.');
  const longSourceOrigin = new URL(sameOrigin).origin + '/';
  assert.equal(longSource.requests.at(-1)?.referer, longSourceOrigin,
    'A source URL over 4096 characters must be reduced to its origin as Referer.');
  assert.equal(longSource.finalDocument.documentReferrer, longSourceOrigin,
    'A source URL over 4096 characters must be reduced to its origin in document.referrer.');

  const credentials = resultById.get('source-credentials-and-fragment');
  const credentialsSource = sourceUrlFor(casesById.get('source-credentials-and-fragment'));
  const sanitizedCredentialsReferer = new URL(credentialsSource);
  sanitizedCredentialsReferer.username = '';
  sanitizedCredentialsReferer.password = '';
  sanitizedCredentialsReferer.hash = '';
  assert.deepEqual(credentials.sourceUrlInput, {
    hasCredentials: true,
    hasFragment: true,
  }, 'The source navigation input must contain both credentials and a fragment.');
  assert.equal(credentials.requests.at(-1)?.referer, sanitizedCredentialsReferer.href,
    'Referer must omit source URL credentials and fragment.');
  assert.equal(credentials.finalDocument.documentReferrer, sanitizedCredentialsReferer.href,
    'document.referrer must omit source URL credentials and fragment.');

  const fixture = normalizeFixtureValue({
    browserVersion: browser.version(),
    browserExecutable: path.basename(browserExecutable),
    oracle: 'Dedicated Chromium 153 headless shell; real HTTP navigation requests served only by two 127.0.0.1 loopback listeners.',
    runner: 'apps/android/tool/parity/verify_document_referrer_browser.mjs',
    runnerSha256: (await import('node:crypto')).createHash('sha256').update(runnerSource).digest('hex'),
    origins: {
      sameOrigin: fixtureSameOrigin,
      crossOrigin: fixtureCrossOrigin,
    },
    policyNames: policies,
    headerMetaPriority,
    headerCaseSensitivity,
    cases: results,
    serverRequests: requests,
    blockedRequests,
  });
  const fixturePath = path.join(
    scriptDirectory,
    '../../../../packages/pirc_render/test/fixtures/parity/document-referrer-chromium153.json',
  );
  await writeFile(fixturePath, JSON.stringify(fixture, null, 2) + '\n');
  process.stdout.write(JSON.stringify({
    browserVersion: browser.version(),
    caseCount: results.length,
    fixturePath,
    headerMetaPriority,
    headerCaseSensitivity,
    cases: results.map(result => ({
      caseId: result.caseId,
      group: result.group,
      policy: result.policy,
      sourceUrlLength: result.sourceDocument.urlLength,
      requestReferers: result.requests.filter(item => item.path !== '/source')
        .map(item => normalizeOrigins(item.referer)),
      documentReferrer: normalizeOrigins(result.finalDocument.documentReferrer),
    })),
  }, null, 2) + '\n');
} finally {
  if (browser) await browser.close();
  await Promise.all([closeServer(sameServer), closeServer(crossServer)]);
}
