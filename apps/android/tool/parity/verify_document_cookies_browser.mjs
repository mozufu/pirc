import { requireTestBrowserExecutable } from './test_browser.mjs';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {createServer} from 'node:http';
import {createRequire} from 'node:module';
import {readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(scriptDirectory, '../../../..');
const require = createRequire(import.meta.url);
const {chromium} = require(require.resolve('playwright-core', {
  paths: [path.join(repositoryRoot, 'apps/gateway')],
}));
const chromePath = requireTestBrowserExecutable();
assert.ok(await import('node:fs').then(fs => fs.existsSync(chromePath)));

const fixtureOrigins = {
  a: 'http://127.0.0.1:43100',
  sameSiteA: 'http://127.0.0.1:43101',
  b: 'http://localhost:43100',
};
const origins = {a: '', sameSiteA: '', b: ''};
const requests = [];
const blockedProxyRequests = [];
const pageRequests = [];

function originFor(name) {
  return origins[name];
}

function escapeHtml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
}

function caseIdFrom(requestUrl, body) {
  return requestUrl.searchParams.get('case') ??
    (body ? new URLSearchParams(body).get('case') : null);
}

function jsonRequest(event) {
  return {
    sequence: event.sequence,
    caseId: event.caseId,
    server: event.server,
    hostname: event.hostname,
    method: event.method,
    url: event.url,
    path: event.path,
    cookie: event.cookie,
    origin: event.origin,
    referer: event.referer,
    authorization: event.authorization,
    authorizationPresent: event.authorizationPresent,
    secFetchSite: event.secFetchSite,
    contentType: event.contentType,
    body: event.body,
    responseStatus: event.responseStatus,
    responseLocation: event.responseLocation,
    responseSetCookie: event.responseSetCookie,
  };
}

function htmlDocument(title, caseId, body = '') {
  return '<!doctype html><html data-case="' + escapeHtml(caseId) + '"><head>' +
    '<meta charset="utf-8"><title>' + escapeHtml(title) + '</title>' +
    '</head><body><h1>' + escapeHtml(title) + '</h1>' + body +
    '<pre id="cookie-start"></pre><script>' +
    'window.__cookieStart={href:location.href,origin:location.origin,pathname:location.pathname,' +
    'documentCookie:document.cookie,referrer:document.referrer};' +
    'document.querySelector("#cookie-start").textContent=JSON.stringify(window.__cookieStart);' +
    '</script></body></html>';
}

function sourceDocument(caseId) {
  const body =
    '<a id="cross-site-get" href="' + escapeHtml(originFor('b') +
      '/cross-get?case=cross-site-get-navigation') + '">Cross-site GET</a>' +
    '<form id="cross-site-post" method="post" action="' + escapeHtml(originFor('b') +
      '/cross-post?case=cross-site-post-navigation') + '">' +
    '<input type="hidden" name="case" value="cross-site-post-navigation">' +
    '<input type="hidden" name="payload" value="synthetic-cookie-post">' +
    '<button type="submit">Cross-site POST</button></form>';
  return htmlDocument('cookie cross-site source', caseId, body);
}

function corsHeaders(request) {
  const origin = request.headers.origin;
  if (!origin) return {};
  return {
    'access-control-allow-origin': origin,
    'access-control-allow-credentials': 'true',
    'access-control-allow-methods': 'GET, POST, OPTIONS',
    'access-control-allow-headers': 'content-type',
    vary: 'Origin',
  };
}

function makeServer() {
  const server = createServer(async (request, response) => {
    const hostHeader = request.headers.host ?? '';
    const hostname = hostHeader.replace(/:\d+$/, '').replace(/^\[|\]$/g, '');
    const baseUrl = 'http://' + hostHeader;
    const requestUrl = new URL(request.url ?? '/', baseUrl);
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const body = Buffer.concat(chunks).toString('utf8');
    const caseId = caseIdFrom(requestUrl, body);
    const event = {
      sequence: requests.length + 1,
      caseId,
      server: hostname,
      hostname,
      method: request.method ?? '',
      url: requestUrl.href,
      path: requestUrl.pathname + requestUrl.search,
      cookie: request.headers.cookie ?? null,
      origin: request.headers.origin ?? null,
      referer: request.headers.referer ?? null,
      authorization: request.headers.authorization ?? null,
      authorizationPresent: Boolean(request.headers.authorization),
      secFetchSite: request.headers['sec-fetch-site'] ?? null,
      contentType: request.headers['content-type'] ?? null,
      body: body || null,
      responseStatus: null,
      responseLocation: null,
      responseSetCookie: null,
    };
    requests.push(event);

    const sendHtml = (status, title, documentCaseId, html, headers = {}) => {
      event.responseStatus = status;
      response.writeHead(status, {
        'content-type': 'text/html; charset=utf-8',
        'cache-control': 'no-store',
        'referrer-policy': 'no-referrer',
        ...headers,
      });
      response.end(html);
    };
    const sendJson = (status, payload, headers = {}) => {
      event.responseStatus = status;
      response.writeHead(status, {
        'content-type': 'application/json; charset=utf-8',
        'cache-control': 'no-store',
        ...corsHeaders(request),
        ...headers,
      });
      response.end(JSON.stringify(typeof payload === 'function' ? payload() : payload));
    };
    const sendEcho = () => sendJson(200, () => ({request: jsonRequest(event)}));

    if (request.method === 'OPTIONS') {
      event.responseStatus = 204;
      response.writeHead(204, {
        'cache-control': 'no-store',
        ...corsHeaders(request),
      });
      response.end();
      return;
    }

    if (request.method === 'GET' && requestUrl.pathname === '/seed-a') {
      const cookies = [
        'a_host=host; Path=/; SameSite=Lax',
        'a_domain=domain; Domain=127.0.0.1; Path=/; SameSite=Lax',
        'a_path=path; Domain=127.0.0.1; Path=/nested; SameSite=Strict',
        'a_http=secret; Path=/; HttpOnly; SameSite=Lax',
        'a_session=session; Path=/; SameSite=Lax',
        'a_persistent=persistent; Path=/; Max-Age=3600; SameSite=Lax',
        'a_default=default; Path=/',
        'a_lax=lax; Path=/; SameSite=Lax',
        'a_strict=strict; Path=/; SameSite=Strict',
        'a_none_insecure=none; Path=/; SameSite=None',
        'a_secure=secure; Path=/; Secure',
        'a_wrong_domain=wrong; Domain=localhost; Path=/',
        'a_expired=dead; Path=/; Max-Age=0',
        '__Secure-no-flag=bad; Path=/',
        '__secure-lowercase=ordinary; Path=/',
        '__secure-lowercase-valid=accepted; Path=/; Secure',
        '__Secure-http-secure=bad; Path=/; Secure',
        '__Host-http-domain=bad; Domain=127.0.0.1; Path=/; Secure',
        '__Host-http-no-path=bad; Secure',
        '__Host-http-no-secure=bad; Path=/',
        '__Host-valid=accepted; Path=/; Secure',
        '__host-lowercase=ordinary; Path=/',
        '__host-lowercase-valid=accepted; Path=/; Secure',
        '__Http-no-http-only=bad; Path=/; Secure',
        '__Http-valid=accepted; Path=/; Secure; HttpOnly',
        '__http-lowercase=ordinary; Path=/',
        '__http-lowercase-valid=accepted; Path=/; Secure; HttpOnly',
        '__Host-Http-no-http-only=bad; Path=/; Secure',
        '__Host-Http-domain=bad; Domain=127.0.0.1; Path=/; Secure; HttpOnly',
        '__Host-Http-valid=accepted; Path=/; Secure; HttpOnly',
        '__host-http-lowercase=ordinary; Path=/; Secure; HttpOnly',
      ];
      const location = originFor('a') + '/nested/landing?case=response-set-cookie-redirect';
      event.responseStatus = 302;
      event.responseLocation = location;
      event.responseSetCookie = cookies;
      response.writeHead(302, {
        'cache-control': 'no-store',
        'referrer-policy': 'no-referrer',
        location,
        'set-cookie': cookies,
      });
      response.end();
      return;
    }

    if (request.method === 'GET' && requestUrl.pathname === '/seed-b') {
      const cookies = [
        'b_host_lax=host; Path=/; SameSite=Lax',
        'b_domain=domain; Domain=localhost; Path=/; SameSite=Lax',
        'b_default=default; Path=/',
        'b_session=session; Path=/; SameSite=Lax',
        'b_persistent=persistent; Path=/; Max-Age=3600; SameSite=Lax',
        'b_lax=lax; Path=/; SameSite=Lax',
        'b_strict=strict; Path=/; SameSite=Strict',
        'b_http=secret; Path=/; HttpOnly; SameSite=Lax',
        'b_none_insecure=bad; Path=/; SameSite=None',
        'b_secure_none=secure; Path=/; SameSite=None; Secure',
        'b_expired=dead; Path=/; Max-Age=0',
        'b_wrong_domain=wrong; Domain=127.0.0.1; Path=/',
      ];
      event.responseStatus = 200;
      event.responseSetCookie = cookies;
      response.writeHead(200, {
        'content-type': 'text/html; charset=utf-8',
        'cache-control': 'no-store',
        'referrer-policy': 'no-referrer',
        'set-cookie': cookies,
      });
      response.end(htmlDocument('cookie B seed', 'cross-site-cookie-seed'));
      return;
    }

    if (request.method === 'GET' && requestUrl.pathname === '/third-party-embed') {
      const frameUrl = originFor('b') + '/iframe-cookie?case=third-party-cookie-frame';
      const body = '<iframe id="cookie-frame" src="' + escapeHtml(frameUrl) + '"></iframe>';
      sendHtml(200, 'third-party cookie top-level page', caseId ?? 'third-party-document-top',
        htmlDocument('third-party cookie top-level page', caseId ?? 'third-party-document-top', body));
      return;
    }

    if (request.method === 'GET' && requestUrl.pathname === '/iframe-cookie') {
      const cookies = [
        'frame_server_lax=lax; Path=/; SameSite=Lax',
        'frame_server_strict=strict; Path=/; SameSite=Strict',
        'frame_server_none=none; Path=/; SameSite=None; Secure',
        'frame_server_http=secret; Path=/; HttpOnly; SameSite=None; Secure',
      ];
      event.responseStatus = 200;
      event.responseSetCookie = cookies;
      response.writeHead(200, {
        'content-type': 'text/html; charset=utf-8',
        'cache-control': 'no-store',
        'referrer-policy': 'no-referrer',
        'set-cookie': cookies,
      });
      response.end(`<!doctype html><html><head><meta charset="utf-8"><title>third-party cookie frame</title></head><body><script>
        const initialDocumentCookie = document.cookie;
        const writes = [];
        const write = (label, value) => {
          document.cookie = value;
          writes.push({label, assignment: value, visibleImmediately: document.cookie});
        };
        write('third-party-lax', 'frame_script_lax=lax; Path=/; SameSite=Lax');
        write('third-party-strict', 'frame_script_strict=strict; Path=/; SameSite=Strict');
        write('third-party-none', 'frame_script_none=none; Path=/; SameSite=None; Secure');
        const documentCookieAfterWrites = document.cookie;
        fetch('/echo?case=third-party-cookie-fetch', {credentials: 'include'})
          .then(response => response.json().then(payload => ({status: response.status, ok: response.ok, request: payload.request})))
          .then(fetchResult => {
            window.__thirdPartyProbe = {
              href: location.href,
              origin: location.origin,
              referrer: document.referrer,
              initialDocumentCookie,
              writes,
              documentCookieAfterWrites,
              documentCookieAfterFetch: document.cookie,
              fetch: fetchResult,
              complete: true,
            };
          })
          .catch(error => {
            window.__thirdPartyProbe = {
              href: location.href,
              origin: location.origin,
              referrer: document.referrer,
              initialDocumentCookie,
              writes,
              documentCookieAfterWrites,
              documentCookieAfterFetch: document.cookie,
              fetchError: {name: error?.name ?? 'Error', message: error?.message ?? String(error)},
              complete: true,
            };
          });
      </script></body></html>`);
      return;
    }

    if (request.method === 'GET' && requestUrl.pathname === '/set-from-fetch') {
      const mode = requestUrl.searchParams.get('mode') ?? 'unknown';
      const cookie = 'fetch_' + mode + '=set; Path=/; SameSite=Lax';
      event.responseSetCookie = [cookie];
      sendJson(200, () => ({request: jsonRequest(event)}), {'set-cookie': cookie});
      return;
    }

    if (request.method === 'GET' && requestUrl.pathname === '/cross-get') {
      const cookie = 'b_redirect=lax; Path=/; SameSite=Lax';
      const location = originFor('b') + '/redirect-final?case=cross-site-get-navigation';
      event.responseStatus = 302;
      event.responseLocation = location;
      event.responseSetCookie = [cookie];
      response.writeHead(302, {
        'cache-control': 'no-store',
        'referrer-policy': 'no-referrer',
        location,
        'set-cookie': cookie,
      });
      response.end();
      return;
    }

    if (request.method === 'GET' && requestUrl.pathname === '/source') {
      sendHtml(200, 'cookie cross-site source', caseId ?? 'cross-site-source', sourceDocument(caseId ?? 'cross-site-source'));
      return;
    }

    if ((request.method === 'GET' || request.method === 'POST') && requestUrl.pathname === '/echo') {
      sendEcho();
      return;
    }

    if (request.method === 'GET' && (requestUrl.pathname === '/nested/echo' || requestUrl.pathname === '/outside/echo')) {
      sendEcho();
      return;
    }

    if ((request.method === 'GET' || request.method === 'POST') && requestUrl.pathname === '/redirect-final') {
      sendHtml(200, 'cookie redirect final', caseId ?? 'cross-site-get-navigation',
        htmlDocument('cookie redirect final', caseId ?? 'cross-site-get-navigation'));
      return;
    }

    if (request.method === 'POST' && requestUrl.pathname === '/cross-post') {
      sendHtml(200, 'cookie cross-site POST result', caseId ?? 'cross-site-post-navigation',
        htmlDocument('cookie cross-site POST result', caseId ?? 'cross-site-post-navigation'));
      return;
    }

    if (request.method === 'GET' && requestUrl.pathname === '/nested/landing') {
      sendHtml(200, 'cookie A nested landing', caseId ?? 'response-set-cookie-redirect',
        htmlDocument('cookie A nested landing', caseId ?? 'response-set-cookie-redirect'));
      return;
    }

    if (request.method === 'GET' && requestUrl.pathname === '/favicon.ico') {
      event.responseStatus = 204;
      response.writeHead(204, {'cache-control': 'no-store'});
      response.end();
      return;
    }

    event.responseStatus = 404;
    response.writeHead(404, {'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store'});
    response.end('Unexpected loopback cookie oracle request');
  });
  return server;
}

async function listen(server, host, port = 0) {
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, host, () => {
      server.off('error', reject);
      resolve();
    });
  });
  const address = server.address();
  assert.ok(address && typeof address === 'object');
  return address.port;
}

async function closeServer(server) {
  if (server?.listening) await new Promise(resolve => server.close(resolve));
}

function launchedChromeCommandLine() {
  const lines = execFileSync('ps', ['-axo', 'pid=,command='], {encoding: 'utf8'}).split('\n');
  const matches = lines.filter(line =>
    line.includes(chromePath) && line.includes('--user-data-dir=') && !line.includes('--type='),
  );
  return matches.at(-1)?.trim() ?? '';
}

async function documentSnapshot(page, label) {
  return page.evaluate(labelValue => ({
    label: labelValue,
    href: location.href,
    origin: location.origin,
    host: location.host,
    pathname: location.pathname,
    documentCookie: document.cookie,
    documentReferrer: document.referrer,
    cookieAtDocumentStart: window.__cookieStart ?? null,
  }), label);
}

const observedCookieNames = new Set([
  'a_session', 'a_persistent', 'a_http', 'a_path', 'script_session', 'script_persistent', 'script_path',
  'b_session', 'b_persistent', 'b_http', 'frame_server_lax', 'frame_server_strict',
  'frame_server_none', 'frame_server_http', 'frame_script_lax', 'frame_script_strict', 'frame_script_none',
  '__Secure-no-flag', '__Secure-http-secure', '__secure-lowercase', '__secure-lowercase-valid',
  '__Host-http-domain', '__Host-http-no-path', '__Host-http-no-secure', '__Host-valid',
  '__host-lowercase', '__host-lowercase-valid', '__Http-no-http-only', '__Http-valid',
  '__http-lowercase', '__http-lowercase-valid', '__Host-Http-no-http-only', '__Host-Http-domain',
  '__Host-Http-valid', '__host-http-lowercase', '__Secure-script', '__secure-script',
  '__Host-script', '__Host-script_path', '__Host-script_flag', '__Host-script-valid',
  '__host-script', '__host-script-valid', '__Http-script', '__Http-script-httpOnly',
  '__http-script', '__Host-Http-script', '__host-http-script',
]);

async function cookieStorageSnapshot(context, label) {
  const cookies = await context.cookies();
  return {
    label,
    source: 'Playwright BrowserContext.cookies() backed by Chrome cookie storage',
    cookies: cookies
      .filter(cookie => observedCookieNames.has(cookie.name))
      .map(cookie => ({
        name: cookie.name,
        value: cookie.value,
        domain: cookie.domain,
        path: cookie.path,
        expires: cookie.expires,
        session: cookie.expires === -1,
        httpOnly: cookie.httpOnly,
        secure: cookie.secure,
        sameSite: cookie.sameSite ?? null,
      }))
      .sort((left, right) => left.name.localeCompare(right.name)),
  };
}

async function collectFetches(page, probes) {
  return page.evaluate(async items => {
    const results = [];
    for (const item of items) {
      try {
        const response = await fetch(item.url, {
          method: item.method ?? 'GET',
          mode: item.mode ?? 'cors',
          credentials: item.credentials,
          headers: item.body ? {'Content-Type': 'application/x-www-form-urlencoded'} : undefined,
          body: item.body ?? undefined,
        });
        const body = await response.json();
        results.push({
          label: item.label,
          status: response.status,
          ok: response.ok,
          serverRequest: body.request ?? null,
          documentCookieImmediatelyAfter: document.cookie,
        });
      } catch (error) {
        results.push({
          label: item.label,
          error: {name: error?.name ?? 'Error', message: error?.message ?? String(error)},
          documentCookieImmediatelyAfter: document.cookie,
        });
      }
    }
    return results;
  }, probes);
}

function normalizeText(text, actualPort, subPort, proxyPort) {
  return String(text)
    .replaceAll('http://127.0.0.1:' + actualPort, fixtureOrigins.a)
    .replaceAll('http://127.0.0.1:' + subPort, fixtureOrigins.sameSiteA)
    .replaceAll('http://localhost:' + actualPort, fixtureOrigins.b)
    .replaceAll('http://127.0.0.1:' + proxyPort, 'http://127.0.0.1:43199');
}

function normalize(value, actualPort, subPort, proxyPort) {
  if (typeof value === 'string') return normalizeText(value, actualPort, subPort, proxyPort);
  if (Array.isArray(value)) return value.map(item => normalize(item, actualPort, subPort, proxyPort));
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, normalize(item, actualPort, subPort, proxyPort)]));
  }
  return value;
}

const serverA = makeServer();
const serverSub = makeServer();
const nonForwardingProxy = createServer((request, response) => {
  blockedProxyRequests.push({method: request.method ?? '', url: request.url ?? '', host: request.headers.host ?? null});
  response.writeHead(403, {'content-type': 'text/plain', connection: 'close'});
  response.end('This loopback-only cookie oracle proxy never forwards.');
});
nonForwardingProxy.on('connect', (request, socket) => {
  blockedProxyRequests.push({method: 'CONNECT', url: request.url ?? '', host: request.headers.host ?? null});
  socket.end('HTTP/1.1 403 Forbidden\\r\\nConnection: close\\r\\n\\r\\n');
});

let browser = null;
let context = null;
try {
  const actualPort = await listen(serverA, '127.0.0.1');
  const subPort = await listen(serverSub, '127.0.0.1');
  origins.a = 'http://127.0.0.1:' + actualPort;
  origins.sameSiteA = 'http://127.0.0.1:' + subPort;
  origins.b = 'http://localhost:' + actualPort;

  const proxyPort = await listen(nonForwardingProxy, '127.0.0.1');
  const proxyOrigin = 'http://127.0.0.1:' + proxyPort;
  browser = await chromium.launch({
    headless: true,
    executablePath: chromePath,
    proxy: {
      server: proxyOrigin,
      bypass: 'localhost,127.0.0.1,[::1]',
    },
    args: [
      '--disable-gpu',
      '--disable-background-networking',
      '--disable-component-update',
      '--disable-sync',
      '--no-first-run',
      '--no-default-browser-check',
      '--host-resolver-rules=MAP localhost 127.0.0.1',
    ],
  });

  context = await browser.newContext();
  context.on('request', request => {
    pageRequests.push({url: request.url(), method: request.method()});
  });
  const page = await context.newPage();

  await page.goto(origins.a + '/seed-a?case=response-set-cookie-redirect', {waitUntil: 'load'});
  const responseLanding = await documentSnapshot(page, 'after-set-cookie-redirect');
  const responseCookieStorage = await cookieStorageSnapshot(context, 'after-response-set-cookie-redirect');

  const scriptOperations = await page.evaluate(async () => {
    const results = [];
    const write = (label, value) => {
      document.cookie = value;
      results.push({label, assignment: value, visibleImmediately: document.cookie});
    };
    write('script-host-root', 'script_root=root; Path=/; SameSite=Lax');
    write('script-domain-root', 'script_domain=domain; Domain=127.0.0.1; Path=/; SameSite=Lax');
    write('script-domain-path', 'script_path=path; Domain=127.0.0.1; Path=/nested; SameSite=Strict');
    write('script-wrong-domain', 'script_wrong_domain=wrong; Domain=localhost; Path=/');
    write('script-secure-on-http', 'script_secure=secure; Path=/; Secure');
    write('script-none-without-secure', 'script_none=none; Path=/; SameSite=None');
    write('secure-prefix-without-secure', '__Secure-script=bad; Path=/');
    write('host-prefix-with-domain', '__Host-script=bad; Domain=127.0.0.1; Path=/; Secure');
    write('host-prefix-without-path', '__Host-script_path=bad; Secure');
    write('host-prefix-without-secure', '__Host-script_flag=bad; Path=/');
    write('host-prefix-valid-secure-loopback', '__Host-script-valid=accepted; Path=/; Secure');
    write('host-prefix-lowercase-no-secure', '__host-script=ordinary; Path=/');
    write('host-prefix-lowercase-valid', '__host-script-valid=ordinary; Path=/; Secure');
    write('secure-prefix-lowercase-no-secure', '__secure-script=ordinary; Path=/');
    write('http-prefix-no-httponly', '__Http-script=bad; Path=/; Secure');
    write('http-prefix-with-js-httponly-attribute', '__Http-script-httpOnly=bad; Path=/; Secure; HttpOnly');
    write('http-prefix-lowercase-not-reserved', '__http-script=ordinary; Path=/');
    write('host-http-prefix-with-js-httponly-attribute', '__Host-Http-script=bad; Path=/; Secure; HttpOnly');
    write('host-http-prefix-lowercase-not-reserved', '__host-http-script=ordinary; Path=/');
    write('overwrite-httponly', 'a_http=overwritten; Path=/; SameSite=Lax');
    write('delete-httponly', 'a_http=; Path=/; Max-Age=0');
    write('script-session', 'script_session=session; Path=/; SameSite=Lax');
    write('script-persistent', 'script_persistent=persistent; Path=/; Max-Age=3600; SameSite=Lax');
    write('max-age-over-expired-expires', 'max_age_wins=live; Path=/; Max-Age=3600; Expires=Thu, 01 Jan 1970 00:00:00 GMT');
    write('duplicate-name-root', 'duplicate=short; Path=/; SameSite=Lax');
    write('duplicate-name-nested', 'duplicate=long; Path=/nested; SameSite=Strict');
    const beforeRootRemoval = document.cookie;
    document.cookie = 'duplicate=; Path=/; Max-Age=0';
    const afterRootRemoval = document.cookie;
    const historyPathSnapshots = [];
    const recordPath = label => historyPathSnapshots.push({
      label,
      href: location.href,
      pathname: location.pathname,
      documentCookie: document.cookie,
    });
    recordPath('nested-before-pushState');
    history.pushState({cookieOracle: true}, '', '/outside/landing?case=pushstate-cookie-path');
    recordPath('outside-after-pushState');
    write('pushstate-default-path', 'pushstate_default=outside-default');
    write('pushstate-explicit-path', 'pushstate_explicit=outside-explicit; Path=/outside; SameSite=Lax');
    const outsideAfterPathCookieWrites = document.cookie;
    const nestedPathRequestAfterPushState = await fetch('/nested/echo?case=script-cookie-nested-path-after-pushstate', {credentials: 'include'})
      .then(response => response.json())
      .then(payload => payload.request);
    const outsidePathRequest = await fetch('/outside/echo?case=script-cookie-outside-path', {credentials: 'include'})
      .then(response => response.json())
      .then(payload => payload.request);
    const outsideAfterFetch = document.cookie;
    recordPath('outside-after-path-fetches');
    history.pushState({cookieOracle: true}, '', '/nested/landing?case=pushstate-cookie-path');
    recordPath('nested-after-pushState-back');
    return {
      results,
      beforeRootRemoval,
      afterRootRemoval,
      historyPathSnapshots,
      outsideAfterPathCookieWrites,
      nestedPathRequestAfterPushState,
      outsidePathRequest,
      outsideAfterFetch,
      finalDocumentCookie: document.cookie,
    };
  });

  const scriptCookieStorage = await cookieStorageSnapshot(context, 'after-script-setters-and-history-path-changes');
  const sameTurnCookieOrder = await page.evaluate(async () => {
    document.cookie = 'sequence=a; Path=/; SameSite=Lax';
    const firstPromise = fetch('/echo?case=same-turn-cookie-a', {credentials: 'include'})
      .then(response => response.json())
      .then(payload => payload.request);
    document.cookie = 'sequence=b; Path=/; SameSite=Lax';
    const secondPromise = fetch('/echo?case=same-turn-cookie-b', {credentials: 'include'})
      .then(response => response.json())
      .then(payload => payload.request);
    const [firstRequest, secondRequest] = await Promise.all([firstPromise, secondPromise]);
    return {
      callOrder: ['set sequence=a', 'fetch first', 'set sequence=b', 'fetch second'],
      firstRequest,
      secondRequest,
      documentCookieAfterBoth: document.cookie,
    };
  });
  const scriptPathProbes = await collectFetches(page, [
    {label: 'nested-path-cookie-request', url: origins.a + '/nested/echo?case=script-cookie-nested-path', credentials: 'include'},
    {label: 'root-path-cookie-request-after-root-duplicate-removal', url: origins.a + '/echo?case=script-cookie-root-path', credentials: 'include'},
  ]);

  const sameOriginFetches = await collectFetches(page, [
    {label: 'same-origin-fetch-credentials-omit', url: origins.a + '/echo?case=fetch-same-origin-omit', credentials: 'omit'},
    {label: 'same-origin-fetch-credentials-same-origin', url: origins.a + '/echo?case=fetch-same-origin-same-origin', credentials: 'same-origin'},
    {label: 'same-origin-fetch-credentials-include', url: origins.a + '/echo?case=fetch-same-origin-include', credentials: 'include'},
    {label: 'same-origin-response-set-cookie-credentials-omit', url: origins.a + '/set-from-fetch?case=fetch-set-cookie-omit&mode=omit', credentials: 'omit'},
    {label: 'same-origin-response-set-cookie-credentials-same-origin', url: origins.a + '/set-from-fetch?case=fetch-set-cookie-same-origin&mode=same-origin', credentials: 'same-origin'},
    {label: 'same-origin-response-set-cookie-credentials-include', url: origins.a + '/set-from-fetch?case=fetch-set-cookie-include&mode=include', credentials: 'include'},
    {label: 'same-origin-fetch-after-response-set-cookie', url: origins.a + '/echo?case=fetch-after-set-cookie', credentials: 'include'},
  ]);
  const sameOriginFetchSnapshot = await documentSnapshot(page, 'after-same-origin-fetches');

  const sameSiteCrossOriginFetches = await collectFetches(page, [
    {label: 'same-site-cross-origin-fetch-credentials-omit', url: origins.sameSiteA + '/nested/echo?case=fetch-same-host-different-port-omit', credentials: 'omit'},
    {label: 'same-site-cross-origin-fetch-credentials-same-origin', url: origins.sameSiteA + '/nested/echo?case=fetch-same-host-different-port-same-origin', credentials: 'same-origin'},
    {label: 'same-site-cross-origin-fetch-credentials-include', url: origins.sameSiteA + '/nested/echo?case=fetch-same-host-different-port-include', credentials: 'include'},
  ]);

  await page.goto(origins.sameSiteA + '/nested/echo?case=domain-scope-same-host-different-port', {waitUntil: 'load'});
  const sameHostDifferentPortSnapshot = await documentSnapshot(page, 'same-host-different-port-cookie-scope');
  const sameHostCookieStorage = await cookieStorageSnapshot(context, 'after-same-host-different-port-navigation');
  await page.goto(origins.b + '/seed-b?case=cross-site-cookie-seed', {waitUntil: 'load'});
  const bSeedSnapshot = await documentSnapshot(page, 'B-cookie-seed');
  const bSeedCookieStorage = await cookieStorageSnapshot(context, 'after-localhost-cookie-seed');
  await page.goto(origins.a + '/third-party-embed?case=third-party-document-top', {waitUntil: 'load'});
  const thirdPartyFrame = page.frames().find(frame => frame.url().includes('/iframe-cookie'));
  assert.ok(thirdPartyFrame, 'Cross-site localhost iframe must load under the 127.0.0.1 top-level page.');
  await thirdPartyFrame.waitForFunction(() => window.__thirdPartyProbe?.complete === true, null, {timeout: 10000});
  const thirdPartyDocumentProbe = await thirdPartyFrame.evaluate(() => ({
    ...window.__thirdPartyProbe,
    finalDocumentCookie: document.cookie,
  }));
  const thirdPartyCookieStorage = await cookieStorageSnapshot(context, 'after-third-party-iframe-cookie-probe');

  const bSeededAt = Date.now();
  await page.goto(origins.a + '/source?case=cross-site-source-fetch', {waitUntil: 'load'});
  const sourceSnapshot = await documentSnapshot(page, 'A-source-with-no-referrer-policy');
  const crossSiteFetches = await collectFetches(page, [
    {label: 'cross-site-fetch-GET-credentials-omit', url: origins.b + '/echo?case=fetch-cross-site-get-omit', credentials: 'omit'},
    {label: 'cross-site-fetch-GET-credentials-same-origin', url: origins.b + '/echo?case=fetch-cross-site-get-same-origin', credentials: 'same-origin'},
    {label: 'cross-site-fetch-GET-credentials-include', url: origins.b + '/echo?case=fetch-cross-site-get-include', credentials: 'include'},
    {label: 'cross-site-fetch-POST-credentials-omit', url: origins.b + '/echo?case=fetch-cross-site-post-omit', method: 'POST', body: 'case=fetch-cross-site-post-omit&payload=synthetic', credentials: 'omit'},
    {label: 'cross-site-fetch-POST-credentials-include', url: origins.b + '/echo?case=fetch-cross-site-post-include', method: 'POST', body: 'case=fetch-cross-site-post-include&payload=synthetic', credentials: 'include'},
  ]);

  const getNavigationPromise = page.waitForNavigation({waitUntil: 'load'});
  await page.locator('#cross-site-get').click();
  const crossSiteGetResponse = await getNavigationPromise;
  const crossSiteGetSnapshot = await documentSnapshot(page, 'cross-site-top-level-GET-final');
  const crossSiteGetStatus = crossSiteGetResponse?.status() ?? null;

  await page.goto(origins.a + '/source?case=cross-site-post-source', {waitUntil: 'load'});
  const defaultCookieAgeMsBeforePost = Date.now() - bSeededAt;
  const postNavigationPromise = page.waitForNavigation({waitUntil: 'load'});
  await page.locator('#cross-site-post button').click();
  const crossSitePostResponse = await postNavigationPromise;
  const crossSitePostSnapshot = await documentSnapshot(page, 'cross-site-top-level-POST-result');
  const crossSitePostStatus = crossSitePostResponse?.status() ?? null;

  const allowedPageRequest = url => {
    if (url === 'about:blank') return true;
    try {
      const parsed = new URL(url);
      return ['127.0.0.1', 'localhost'].includes(parsed.hostname);
    } catch (_) {
      return false;
    }
  };
  const unexpectedPageRequests = pageRequests.filter(request => !allowedPageRequest(request.url));
  assert.deepEqual(unexpectedPageRequests, [], 'Chrome page requests must stay on the synthetic loopback hosts.');

  const crossSiteEvidence = requests.filter(item =>
    String(item.caseId).startsWith('fetch-cross-site-') ||
    (item.caseId === 'cross-site-get-navigation' && item.path.startsWith('/cross-get?')) ||
    (item.caseId === 'cross-site-post-navigation' && item.path.startsWith('/cross-post?'))
  );
  assert.ok(crossSiteEvidence.length > 0, 'Cross-site probes must reach the loopback server.');
  assert.ok(crossSiteEvidence.every(item => item.secFetchSite === 'cross-site'),
    'Chrome must classify 127.0.0.1 and localhost as cross-site.');
  const sameSiteEvidence = requests.filter(item => String(item.caseId).startsWith('fetch-same-host-different-port-'));
  assert.ok(sameSiteEvidence.length > 0, 'Same-site cross-origin probes must reach the loopback server.');
  assert.ok(sameSiteEvidence.every(item => item.secFetchSite === 'same-site'),
    'Chrome must classify the same-IP different-port fetches as same-site: ' + JSON.stringify(sameSiteEvidence));

  const commandLine = launchedChromeCommandLine();
  const blockedCountsByMethod = blockedProxyRequests.reduce((counts, item) => {
    counts[item.method] = (counts[item.method] ?? 0) + 1;
    return counts;
  }, {});
  const runnerBytes = await readFile(fileURLToPath(import.meta.url));
  const normalizedRequests = normalize(requests, actualPort, subPort, proxyPort);
  const caseRequestSequences = caseId => requests.filter(item => item.caseId === caseId).map(item => item.sequence);
  const rawFixture = {
    browserVersion: browser.version(),
    browserExecutable: chromePath,
    runner: 'apps/android/tool/parity/verify_document_cookies_browser.mjs',
    runnerSha256: createHash('sha256').update(runnerBytes).digest('hex'),
    browserFlags: {
      disableBackForwardCacheFlagPresent: commandLine.includes('--disable-back-forward-cache'),
      commandLineCaptured: Boolean(commandLine),
      hostResolverRulesConfiguredByRunner: true,
      browserExternalProxyConfiguredByRunner: true,
      observedChromeCommandLine: commandLine || null,
      backgroundNetworkingDisabledByRunner: true,
      thirdPartyCookieFlagsOverriddenByRunner: false,
    },
    origins: {
      a: fixtureOrigins.a,
      sameSiteA: fixtureOrigins.sameSiteA,
      b: fixtureOrigins.b,
      siteRelation: 'a and sameSiteA are 127.0.0.1 with different ports: same-site but cross-origin. b is localhost on the a port, a distinct site. Chrome maps localhost to 127.0.0.1. Same-site and cross-site classifications are recorded from each actual Sec-Fetch-Site request header.',
    },
    caseCount: 7,
    caseSources: [
      {caseId: 'response-set-cookie-redirect', source: 'GET /seed-a returns the recorded Set-Cookie headers and a 302 to /nested/landing; both actual navigation requests are stored in serverRequests.'},
      {caseId: 'script-cookie-api', source: 'document.cookie setters and synchronous reads, HttpOnly overwrite/removal attempts, duplicate-name deletion, history.pushState path visibility, default-path and explicit-path setters, and actual /nested/echo and /outside/echo requests while the document URL is /outside; same-turn writes around two fetch calls are also recorded.'},
      {caseId: 'fetch-credentials-and-response-set-cookie', source: 'Same-origin fetch requests use omit, same-origin, and include credentials; /set-from-fetch returns Set-Cookie and /echo records later transmission.'},
      {caseId: 'host-only-domain-and-path-scope', source: 'Host-only and Domain cookie storage metadata, Path matching, requests at a second port on 127.0.0.1, and separation from the distinct localhost host.'},
      {caseId: 'third-party-cookie-document-context', source: 'A localhost iframe under a 127.0.0.1 top-level page records cookie visibility before and after Lax, Strict, and None setters, the actual same-origin frame fetch, and Chrome cookie storage metadata.'},
      {caseId: 'cross-site-cookie-seed', source: 'GET /seed-b (localhost) returns the recorded Lax, Strict, default, HttpOnly, Secure, and invalid SameSite=None cookie headers.'},
      {caseId: 'cross-site-delivery-and-referrer-policy', source: 'A no-referrer source runs cross-site fetch GET/POST probes, follows a cross-site anchor GET through a Set-Cookie redirect, and submits a cross-site form POST.'},
    ],
    cases: [
      {
        caseId: 'response-set-cookie-redirect',
        requestSequences: caseRequestSequences('response-set-cookie-redirect'),
        sourceResponseSetCookie: requests.find(item => item.path.startsWith('/seed-a?'))?.responseSetCookie ?? [],
        document: responseLanding,
        cookieStorage: responseCookieStorage,
      },
      {
        caseId: 'script-cookie-api',
        requestSequences: [
          ...caseRequestSequences('script-cookie-nested-path'),
          ...caseRequestSequences('script-cookie-root-path'),
          ...caseRequestSequences('same-turn-cookie-a'),
          ...caseRequestSequences('same-turn-cookie-b'),
        ],
        scriptOperations,
        cookieStorage: scriptCookieStorage,
        sameTurnCookieOrder,
        pathProbes: scriptPathProbes,
      },
      {
        caseId: 'fetch-credentials-and-response-set-cookie',
        requestSequences: requests.filter(item => String(item.caseId).startsWith('fetch-')).map(item => item.sequence),
        fetchResults: sameOriginFetches,
        documentAfterFetches: sameOriginFetchSnapshot,
      },
      {
        caseId: 'host-only-domain-and-path-scope',
        requestSequences: caseRequestSequences('domain-scope-same-host-different-port'),
        sameHostDifferentPortDocument: sameHostDifferentPortSnapshot,
        sameHostDifferentPortRequest: requests.find(item => item.caseId === 'domain-scope-same-host-different-port') ?? null,
        sameHostDifferentPortCookieStorage: sameHostCookieStorage,
        sameSiteCrossOriginFetches: sameSiteCrossOriginFetches,
      },
      {
        caseId: 'cross-site-cookie-seed',
        requestSequences: caseRequestSequences('cross-site-cookie-seed'),
        sourceResponseSetCookie: requests.find(item => item.path.startsWith('/seed-b?'))?.responseSetCookie ?? [],
        document: bSeedSnapshot,
        cookieStorage: bSeedCookieStorage,
        ageMsBeforeTopLevelPost: defaultCookieAgeMsBeforePost,
      },
      {
        caseId: 'third-party-cookie-document-context',
        requestSequences: requests
          .filter(item => String(item.caseId).startsWith('third-party-'))
          .map(item => item.sequence),
        topLevelDocument: requests.find(item => item.caseId === 'third-party-document-top') ?? null,
        frameDocument: requests.find(item => item.caseId === 'third-party-cookie-frame') ?? null,
        frameProbe: thirdPartyDocumentProbe,
        cookieStorage: thirdPartyCookieStorage,
      },
      {
        caseId: 'cross-site-delivery-and-referrer-policy',
        requestSequences: requests
          .filter(item => String(item.caseId).startsWith('fetch-cross-site-') ||
            item.caseId === 'cross-site-get-navigation' ||
            item.caseId === 'cross-site-post-navigation')
          .map(item => item.sequence),
        sourceDocument: sourceSnapshot,
        sourceResponseReferrerPolicy: 'no-referrer',
        fetchResults: crossSiteFetches,
        topLevelGet: {
          responseStatus: crossSiteGetStatus,
          document: crossSiteGetSnapshot,
          redirectRequestSequences: caseRequestSequences('cross-site-get-navigation'),
        },
        topLevelPost: {
          responseStatus: crossSitePostStatus,
          document: crossSitePostSnapshot,
          requestSequences: caseRequestSequences('cross-site-post-navigation'),
          defaultCookieAgeMsBeforePost,
        },
      },
    ],
    serverRequests: normalizedRequests.map(item => normalize(item, actualPort, subPort, proxyPort)),
    externalProxy: {
      origin: 'http://127.0.0.1:43199',
      forwardsRequests: false,
      blockedRequestCount: blockedProxyRequests.length,
      blockedCountsByMethod,
      pageRequestsStayedOnSyntheticLoopbackHosts: unexpectedPageRequests.length === 0,
      unexpectedPageRequests,
    },
    scope: {
      transport: 'Plain HTTP requests used only 127.0.0.1 and localhost. Both Node servers bind 127.0.0.1; localhost is explicitly mapped to 127.0.0.1. The same-site origin uses a second port on 127.0.0.1. Chrome accepted Secure cookies on loopback HTTP in this run. TLS was not tested.',
      cookieKinds: 'HttpOnly invisibility and overwrite/removal attempts, host-only and Domain scope, Path matching, script setters with synchronous reads, Max-Age removal/precedence, __Secure-, __Host-, __Http-, and __Host-Http- prefix cases, credentials modes, response Set-Cookie, redirect handling, and SameSite Lax/Strict/default delivery were probed.',
      notTested: 'Subdomain Domain-suffix matching (the permitted hosts are only 127.0.0.1 and localhost), Partitioned/CHIPS cookies, third-party-cookie setting permutations, private suffix/public-suffix edge cases, cookie eviction/quota, cross-process profiles, service workers, and TLS transport. One default third-party iframe context was probed; this does not establish behavior under other profile settings.',
      referrer: 'Cross-site source HTML is served with Referrer-Policy: no-referrer. Each request records actual Referer, Cookie, Origin, Authorization, method, and Sec-Fetch-Site headers observed by the loopback server.',
      cache: 'All probe responses use Cache-Control: no-store. A single fresh Playwright browser context shares the cookie jar across the recorded sequence.',
    },
  };
  const fixture = normalize(rawFixture, actualPort, subPort, proxyPort);
  const fixturePath = process.env.PIRC_FIXTURE_PATH ??
    path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-cookies-chrome155.json');
  await writeFile(fixturePath, JSON.stringify(fixture, null, 2) + '\n');
  process.stdout.write(JSON.stringify({
    browserVersion: fixture.browserVersion,
    fixturePath,
    runnerSha256: fixture.runnerSha256,
    caseCount: fixture.caseCount,
    requestCount: fixture.serverRequests.length,
    navigationRequestCount: fixture.serverRequests.filter(item => item.method === 'GET' && !item.path.startsWith('/favicon')).length,
    blockedProxyRequestCount: fixture.externalProxy.blockedRequestCount,
    blockedCountsByMethod,
    cookieHeadersObserved: fixture.serverRequests.filter(item => item.cookie).length,
    missingAuthorizationCount: fixture.serverRequests.filter(item => !item.authorizationPresent).length,
    cases: fixture.cases.map(item => item.caseId),
  }, null, 2) + '\n');
} finally {
  if (context) await context.close();
  if (browser) await browser.close();
  await Promise.all([closeServer(serverA), closeServer(serverSub), closeServer(nonForwardingProxy)]);
}
