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
const browserExecutable = chromePath;
assert.ok(await import('node:fs').then(fs => fs.existsSync(browserExecutable)));

const policyNames = [
  'no-referrer',
  'no-referrer-when-downgrade',
  'origin',
  'origin-when-cross-origin',
  'same-origin',
  'strict-origin',
  'strict-origin-when-cross-origin',
  'unsafe-url',
];

const cases = [
  {caseId: 'post-same-origin', kind: 'form', method: 'POST', targetOrigin: 'a', targetPath: '/echo'},
  {caseId: 'post-cross-site', kind: 'form', method: 'POST', targetOrigin: 'b', targetPath: '/echo'},
  {caseId: 'get-form-same-origin', kind: 'form', method: 'GET', targetOrigin: 'a', targetPath: '/echo'},
  {caseId: 'get-anchor-cross-site', kind: 'anchor', method: 'GET', targetOrigin: 'b', targetPath: '/echo'},
  {caseId: 'post-origin-guard-cross-site', kind: 'form', method: 'POST', targetOrigin: 'b', targetPath: '/guard-a', guard: 'a'},
  {caseId: 'post-opaque-sandbox-null-origin', kind: 'opaque-frame', method: 'POST', targetOrigin: 'b', targetPath: '/guard-null', guard: 'null'},
  {caseId: 'post-referrer-header-only', kind: 'form', method: 'POST', targetOrigin: 'b', targetPath: '/echo', headerPolicy: 'unsafe-url'},
  {caseId: 'post-referrer-meta-only', kind: 'form', method: 'POST', targetOrigin: 'b', targetPath: '/echo', metaPolicy: 'unsafe-url'},
  {caseId: 'post-referrer-header-meta-conflict', kind: 'form', method: 'POST', targetOrigin: 'b', targetPath: '/echo', headerPolicy: 'no-referrer', metaPolicy: 'unsafe-url'},
  {caseId: 'post-referrer-meta-over-header', kind: 'form', method: 'POST', targetOrigin: 'b', targetPath: '/echo', headerPolicy: 'unsafe-url', metaPolicy: 'no-referrer'},
  {caseId: 'post-referrer-element-over-meta', kind: 'form', method: 'POST', targetOrigin: 'b', targetPath: '/echo', headerPolicy: 'unsafe-url', metaPolicy: 'no-referrer', elementPolicy: 'origin'},
  {caseId: 'post-referrer-element-unsafe-url-only', kind: 'form', method: 'POST', targetOrigin: 'b', targetPath: '/echo', elementPolicy: 'unsafe-url'},
  {caseId: 'post-referrer-rel-noreferrer', kind: 'form', method: 'POST', targetOrigin: 'b', targetPath: '/echo', headerPolicy: 'unsafe-url', formRel: 'noreferrer'},
  {caseId: 'post-redirect-301', kind: 'form', method: 'POST', targetOrigin: 'b', targetPath: '/redirect/301', redirectFinalOrigin: 'c'},
  {caseId: 'post-redirect-302', kind: 'form', method: 'POST', targetOrigin: 'b', targetPath: '/redirect/302', redirectFinalOrigin: 'c'},
  {caseId: 'post-redirect-303', kind: 'form', method: 'POST', targetOrigin: 'b', targetPath: '/redirect/303', redirectFinalOrigin: 'c'},
  {caseId: 'post-redirect-307', kind: 'form', method: 'POST', targetOrigin: 'b', targetPath: '/redirect/307', redirectFinalOrigin: 'c'},
  {caseId: 'post-redirect-308', kind: 'form', method: 'POST', targetOrigin: 'b', targetPath: '/redirect/308', redirectFinalOrigin: 'c'},
  {caseId: 'post-redirect-taint-a-b-a', kind: 'form', method: 'POST', targetOrigin: 'b', targetPath: '/redirect/taint-start', redirectFinalOrigin: 'a', taintRoute: 'a-b-a'},
  {caseId: 'post-redirect-taint-a-b-a-c', kind: 'form', method: 'POST', targetOrigin: 'b', targetPath: '/redirect/taint-start', redirectFinalOrigin: 'c', taintRoute: 'a-b-a-c'},
  {caseId: 'post-reload-cross-site', kind: 'reload', method: 'POST', targetOrigin: 'b', targetPath: '/echo', reloadAfterSubmit: true},
  {caseId: 'post-reload-after-307-to-a', kind: 'reload', method: 'POST', targetOrigin: 'b', targetPath: '/redirect/307-to-a', redirectFinalOrigin: 'a', reloadAfterSubmit: true},
  {caseId: 'post-reload-no-referrer-meta-unsafe', kind: 'reload', method: 'POST', targetOrigin: 'b', targetPath: '/echo', headerPolicy: 'no-referrer', finalMetaPolicy: 'unsafe-url', reloadAfterSubmit: true},
  {caseId: 'post-blob-creator-cross-site', kind: 'blob', method: 'POST', targetOrigin: 'b', targetPath: '/echo'},
  {caseId: 'post-blob-creator-no-referrer-cross-site', kind: 'blob', method: 'POST', targetOrigin: 'b', targetPath: '/echo', headerPolicy: 'no-referrer'},
  {caseId: 'post-named-target-source-origin', kind: 'named-target', method: 'POST', targetOrigin: 'c', targetPath: '/echo', namedInitialOrigin: 'b'},
];
for (const policy of policyNames) {
  cases.push({
    caseId: 'post-policy-' + policy,
    kind: 'form',
    method: 'POST',
    targetOrigin: 'b',
    targetPath: '/echo',
    headerPolicy: policy,
  });
}
for (const policy of policyNames) {
  cases.push({
    caseId: 'post-policy-element-' + policy,
    kind: 'form',
    method: 'POST',
    targetOrigin: 'b',
    targetPath: '/echo',
    elementPolicy: policy,
  });
}
assert.equal(cases.length, 42, 'Keep the explicit 42-case Origin oracle frozen.');
const selectedCases = process.env.PIRC_CASE_FILTER
  ? cases.filter(spec => process.env.PIRC_CASE_FILTER.split(',').includes(spec.caseId))
  : cases;
assert.ok(selectedCases.length > 0, 'PIRC_CASE_FILTER must select at least one known case.');

const caseById = new Map(cases.map(spec => [spec.caseId, spec]));
const requests = [];
const proxyBlocked = [];
const pageRequests = [];
const origins = {a: '', b: '', c: ''};
const fixtureOrigins = {
  a: 'http://127.0.0.1:43180',
  b: 'http://localhost:43181',
  c: 'http://127.0.0.1:43182',
};
const servers = {};

function originFor(name) {
  return origins[name];
}

function fixtureOriginFor(name) {
  return fixtureOrigins[name];
}

function escapeHtml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
}

function instrumentedScript() {
  return '<script>' +
    'window.__originProbeEvents=[{event:"document-start",url:location.href,origin:location.origin,timeOrigin:performance.timeOrigin}];' +
    'for(const name of ["pageshow","pagehide","load","hashchange"]){window.addEventListener(name,e=>window.__originProbeEvents.push({event:name,persisted:Boolean(e.persisted),url:location.href,origin:location.origin,timeOrigin:performance.timeOrigin}));}' +
    '</script>';
}

function referrerObservationMarkup() {
  return '<pre id="referrer-observation"></pre>' +
    '<script>document.querySelector("#referrer-observation").textContent=JSON.stringify({url:location.href,referrer:document.referrer});</script>';
}

function formFields(spec) {
  return [
    ['payload', 'synthetic-' + spec.caseId],
    ['case', spec.caseId],
  ];
}

function actionUrlFor(spec) {
  const targetOrigin = originFor(spec.targetOrigin);
  return targetOrigin + spec.targetPath + '?case=' + encodeURIComponent(spec.caseId);
}

function actionUrlForNamedInitial(spec) {
  return originFor(spec.namedInitialOrigin) + '/named-initial?case=' + encodeURIComponent(spec.caseId);
}

function sourceUrlFor(spec) {
  return originFor('a') + '/source?case=' + encodeURIComponent(spec.caseId);
}

function hiddenFieldsHtml(spec) {
  const fields = formFields(spec);
  return fields.map(pair =>
    '<input type="hidden" name="' + escapeHtml(pair[0]) + '" value="' + escapeHtml(pair[1]) + '">',
  ).join('');
}

function formHtml(spec, opts = {}) {
  const method = spec.method.toLowerCase();
  const action = opts.actionUrl ?? actionUrlFor(spec);
  const target = opts.target ?? '';
  const rel = opts.rel ?? spec.formRel ?? '';
  const referrerPolicy = opts.referrerPolicy ?? spec.elementPolicy ?? '';
  const targetAttr = target ? ' target="' + escapeHtml(target) + '"' : '';
  const relAttr = rel ? ' rel="' + escapeHtml(rel) + '"' : '';
  const policyAttr = referrerPolicy ? ' referrerpolicy="' + escapeHtml(referrerPolicy) + '"' : '';
  const buttonLabel = opts.buttonLabel ?? (method === 'post' ? 'Submit POST' : 'Submit GET');
  return '<form id="origin-form" action="' + escapeHtml(action) + '" method="' + method + '"' +
    targetAttr + relAttr + policyAttr + '>' + hiddenFieldsHtml(spec) +
    '<button id="submit-form" type="submit">' + buttonLabel + '</button></form>';
}

function blobDocumentHtml(spec) {
  return '<!doctype html><html><head><meta charset="utf-8"><title>Blob Origin source</title>' +
    instrumentedScript() + '</head><body><h1>Blob form</h1>' +
    formHtml(spec) + referrerObservationMarkup() + '</body></html>';
}

function opaqueFrameHtml(spec) {
  return '<!doctype html><html><head><meta charset="utf-8"><title>Opaque sandbox source</title>' +
    instrumentedScript() + '</head><body>' +
    formHtml(spec, {buttonLabel: 'Submit opaque POST'}) +
    referrerObservationMarkup() + '</body></html>';
}

function sourceHtmlFor(spec) {
  const meta = spec.metaPolicy
    ? '<meta name="referrer" content="' + escapeHtml(spec.metaPolicy) + '">'
    : '';
  const finalMeta = '';
  const header = '';
  let body = '';
  let embeddedHtml = null;
  if (spec.kind === 'anchor') {
    body = '<a id="navigate" href="' + escapeHtml(actionUrlFor(spec)) + '">Navigate with GET</a>';
  } else if (spec.kind === 'opaque-frame') {
    embeddedHtml = opaqueFrameHtml(spec);
    body = '<iframe id="opaque-frame" name="opaque-origin-frame" sandbox="allow-forms allow-scripts" srcdoc="' +
      escapeHtml(embeddedHtml) + '"></iframe>';
  } else if (spec.kind === 'blob') {
    embeddedHtml = blobDocumentHtml(spec);
    const embeddedJson = JSON.stringify(embeddedHtml).replaceAll('</script', '<\\/script');
    body = '<a id="blob-link" href="#">Open Blob form</a>' +
      '<script type="application/json" id="blob-source">' + embeddedJson + '</script>' +
      '<script>const sourceHtml=JSON.parse(document.querySelector("#blob-source").textContent);' +
      'window.__blobUrl=URL.createObjectURL(new Blob([sourceHtml],{type:"text/html"}));' +
      'document.querySelector("#blob-link").href=window.__blobUrl;</script>';
  } else if (spec.kind === 'named-target') {
    const namedAction = actionUrlFor(spec);
    body = '<a id="open-named-target" href="' + escapeHtml(actionUrlForNamedInitial(spec)) +
      '" target="origin-named-target">Open named target</a>' +
      formHtml(spec, {actionUrl: namedAction, target: 'origin-named-target'});
  } else {
    body = formHtml(spec);
  }
  const policyMeta = meta || finalMeta;
  const policyHeaderMarker = header;
  const text = '<!doctype html><html><head><meta charset="utf-8">' +
    policyMeta + '<title>Origin source ' + escapeHtml(spec.caseId) + '</title>' +
    instrumentedScript() + '</head><body data-case="' + escapeHtml(spec.caseId) + '">' +
    '<h1>Origin source ' + escapeHtml(spec.caseId) + '</h1>' + body +
    referrerObservationMarkup() +
    '<!-- response header policy marker: ' + escapeHtml(policyHeaderMarker) + ' -->' +
    '</body></html>';
  return {html: text, embeddedHtml};
}

function finalDocumentHtml(spec, requestEvent, serverName, options = {}) {
  const meta = spec.finalMetaPolicy
    ? '<meta name="referrer" content="' + escapeHtml(spec.finalMetaPolicy) + '">'
    : '';
  const guardInfo = options.guard
    ? '<p id="guard-result" data-origin-guard="true" data-accepted="' +
      String(options.guard.accepted) + '">Origin guard ' +
      (options.guard.accepted ? 'accepted' : 'rejected') +
      '; expected Origin=' + escapeHtml(options.guard.expected) +
      '; actual Origin=' + escapeHtml(requestEvent.origin ?? '<absent>') + '</p>'
    : '';
  const serverObservation = {
    caseId: spec.caseId,
    server: serverName,
    method: requestEvent.method,
    path: requestEvent.path,
    body: requestEvent.body,
    origin: requestEvent.origin,
    referer: requestEvent.referer,
    authorization: requestEvent.authorization,
    requestOriginSource: requestEvent.requestOriginSource,
  };
  return '<!doctype html><html data-case="' + escapeHtml(spec.caseId) +
    '" data-generation="' + String(requestEvent.sequence) + '"><head><meta charset="utf-8">' +
    meta + '<title>' + escapeHtml(spec.caseId) + ' final</title>' +
    instrumentedScript() + '</head><body><h1>' + escapeHtml(spec.caseId) + ' final</h1>' +
    guardInfo + '<pre id="server-observation">' + escapeHtml(JSON.stringify(serverObservation)) +
    '</pre><p id="request-body">' + escapeHtml(requestEvent.body ?? '') + '</p>' +
    referrerObservationMarkup() +
    '</body></html>';
}

function redirectTargetFor(spec, serverName, requestUrl) {
  if (requestUrl.pathname.startsWith('/redirect/3') ||
      requestUrl.pathname === '/redirect/301' ||
      requestUrl.pathname === '/redirect/302' ||
      requestUrl.pathname === '/redirect/303' ||
      requestUrl.pathname === '/redirect/307' ||
      requestUrl.pathname === '/redirect/308') {
    return originFor(spec.redirectFinalOrigin ?? 'c') + '/final?case=' + encodeURIComponent(spec.caseId);
  }
  if (requestUrl.pathname === '/redirect/307-to-a') {
    return originFor('a') + '/final?case=' + encodeURIComponent(spec.caseId);
  }
  if (requestUrl.pathname === '/redirect/taint-start') {
    if (spec.taintRoute === 'a-b-a') {
      return originFor('a') + '/final?case=' + encodeURIComponent(spec.caseId);
    }
    return originFor('a') + '/redirect/taint-continue?case=' + encodeURIComponent(spec.caseId);
  }
  if (requestUrl.pathname === '/redirect/taint-continue') {
    return originFor('c') + '/final?case=' + encodeURIComponent(spec.caseId);
  }
  return null;
}

function requestOriginSource(spec, requestUrl, originHeader) {
  if (originHeader === 'null') return 'null';
  if (typeof originHeader === 'string') return originHeader;
  if (requestUrl.pathname === '/source') return null;
  if (spec?.kind === 'opaque-frame') return 'null';
  return spec ? originFor('a') : null;
}

function requestBodyFor(request, chunks) {
  return Buffer.concat(chunks).toString('utf8');
}

function makeServer(serverName) {
  return createServer(async (request, response) => {
    const baseOrigin = originFor(serverName);
    const requestUrl = new URL(request.url ?? '/', baseOrigin || 'http://127.0.0.1');
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const body = requestBodyFor(request, chunks);
    const parsedBody = new URLSearchParams(body);
    const caseId = requestUrl.searchParams.get('case') ?? parsedBody.get('case') ?? '';
    const spec = caseById.get(caseId) ?? null;
    const rawOrigin = request.headers.origin ?? null;
    const rawReferer = request.headers.referer ?? null;
    const rawAuthorization = request.headers.authorization ?? null;
    const event = {
      sequence: requests.length + 1,
      caseId: caseId || null,
      server: serverName,
      serverOrigin: baseOrigin,
      method: request.method ?? '',
      url: requestUrl.href,
      path: requestUrl.pathname + requestUrl.search,
      body: body || null,
      origin: rawOrigin,
      requestOrigin: rawOrigin,
      requestOriginSource: requestOriginSource(spec, requestUrl, rawOrigin),
      referer: rawReferer,
      authorization: rawAuthorization,
      authorizationPresent: Boolean(rawAuthorization),
      contentType: request.headers['content-type'] ?? null,
      secFetchSite: request.headers['sec-fetch-site'] ?? null,
      secFetchMode: request.headers['sec-fetch-mode'] ?? null,
      secFetchDest: request.headers['sec-fetch-dest'] ?? null,
      responseStatus: null,
      responseLocation: null,
      responseReferrerPolicy: null,
      responseOriginGuard: false,
      responseGuardExpectedOrigin: null,
      responseBody: '',
    };
    requests.push(event);

    if (request.method === 'GET' && requestUrl.pathname === '/favicon.ico') {
      event.responseStatus = 204;
      response.writeHead(204, {'cache-control': 'no-store'});
      response.end();
      return;
    }

    if (request.method === 'GET' && requestUrl.pathname === '/source' && serverName === 'a' && spec) {
      const generated = sourceHtmlFor(spec);
      spec.sourceHtml = generated.html;
      spec.embeddedHtml = generated.embeddedHtml;
      event.responseStatus = 200;
      event.responseReferrerPolicy = spec.headerPolicy ?? null;
      event.responseBody = generated.html;
      response.writeHead(200, {
        'content-type': 'text/html; charset=utf-8',
        'cache-control': 'no-store',
        ...(spec.headerPolicy ? {'referrer-policy': spec.headerPolicy} : {}),
      });
      response.end(generated.html);
      return;
    }

    const redirectTarget = spec ? redirectTargetFor(spec, serverName, requestUrl) : null;
    const redirectStatusMatch = requestUrl.pathname.match(/^\/redirect\/(30[123]|30[78])$/);
    if (redirectTarget && requestUrl.pathname.startsWith('/redirect/')) {
      const status = redirectStatusMatch
        ? Number(redirectStatusMatch[1])
        : 307;
      event.responseStatus = status;
      event.responseLocation = redirectTarget;
      event.responseBody = '';
      response.writeHead(status, {
        'cache-control': 'no-store',
        'location': redirectTarget,
      });
      response.end();
      return;
    }

    if (request.method === 'POST' && requestUrl.pathname === '/guard-a') {
      const expected = originFor('a');
      const accepted = rawOrigin === expected;
      event.responseOriginGuard = true;
      event.responseGuardExpectedOrigin = expected;
      event.responseStatus = accepted ? 200 : 403;
      const html = finalDocumentHtml(spec, event, serverName, {
        guard: {expected, accepted},
      });
      event.responseBody = html;
      response.writeHead(event.responseStatus, {
        'content-type': 'text/html; charset=utf-8',
        'cache-control': 'no-store',
      });
      response.end(html);
      return;
    }

    if (request.method === 'POST' && requestUrl.pathname === '/guard-null') {
      const expected = 'null';
      const accepted = rawOrigin === expected;
      event.responseOriginGuard = true;
      event.responseGuardExpectedOrigin = expected;
      event.responseStatus = accepted ? 200 : 403;
      const html = finalDocumentHtml(spec, event, serverName, {
        guard: {expected, accepted},
      });
      event.responseBody = html;
      response.writeHead(event.responseStatus, {
        'content-type': 'text/html; charset=utf-8',
        'cache-control': 'no-store',
      });
      response.end(html);
      return;
    }

    if (request.method === 'GET' || request.method === 'POST') {
      event.responseStatus = 200;
      const html = finalDocumentHtml(spec ?? {caseId: ''}, event, serverName);
      event.responseBody = html;
      response.writeHead(200, {
        'content-type': 'text/html; charset=utf-8',
        'cache-control': 'no-store',
      });
      response.end(html);
      return;
    }

    event.responseStatus = 404;
    event.responseBody = 'unexpected loopback oracle request';
    response.writeHead(404, {
      'content-type': 'text/plain; charset=utf-8',
      'cache-control': 'no-store',
    });
    response.end(event.responseBody);
  });
}

async function listen(server, host) {
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, host, () => {
      server.off('error', reject);
      resolve();
    });
  });
  const address = server.address();
  assert.ok(address && typeof address === 'object');
  return 'http://' + host + ':' + address.port;
}

async function closeServer(server) {
  if (!server.listening) return;
  await new Promise(resolve => server.close(resolve));
}

function launchedChromeCommandLine() {
  const lines = execFileSync('ps', ['-axo', 'pid=,command='], {encoding: 'utf8'}).split('\n');
  const matches = lines.filter(line =>
    line.includes(chromePath) && line.includes('--user-data-dir=') && !line.includes('--type='),
  );
  return matches.at(-1)?.trim() ?? '';
}

function normalizeOrigins(value) {
  let text = value;
  for (const name of ['a', 'b', 'c']) {
    text = text.replaceAll(originFor(name), fixtureOriginFor(name));
  }
  return text;
}

function normalizeFixtureValue(value) {
  if (typeof value === 'string') return normalizeOrigins(value);
  if (Array.isArray(value)) return value.map(normalizeFixtureValue);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, normalizeFixtureValue(item)]));
  }
  return value;
}

async function snapshotDocument(page, label) {
  return page.evaluate(labelValue => {
    const serverEvent = document.querySelector('#server-observation')?.textContent ?? '';
    const referrerObservationText = document.querySelector('#referrer-observation')?.textContent ?? '';
    let parsedServerEvent = null;
    let parsedReferrerObservation = null;
    try { parsedServerEvent = JSON.parse(serverEvent); } catch (_) {}
    try { parsedReferrerObservation = JSON.parse(referrerObservationText); } catch (_) {}
    return {
      label: labelValue,
      url: location.href,
      origin: location.origin,
      documentReferrer: document.referrer,
      documentReferrerPolicy: document.referrerPolicy ?? null,
      referrerObservation: parsedReferrerObservation,
      title: document.title,
      bodyText: document.body?.innerText ?? '',
      bodyGeneration: document.documentElement.dataset.generation ?? null,
      performanceTimeOrigin: performance.timeOrigin,
      serverObservation: parsedServerEvent,
      events: window.__originProbeEvents ?? [],
    };
  }, label);
}

function outcomeFromResponse(response, step) {
  return {
    step,
    status: response?.status() ?? null,
    url: response?.url() ?? null,
  };
}

async function executeSpec(browser, spec) {
  const requestStart = requests.length;
  const pageRequestStart = pageRequests.length;
  const context = await browser.newContext();
  const unexpectedPageRequests = [];
  const pageErrors = [];
  const consoleMessages = [];
  const dialogEvents = [];
  const navigationErrors = [];
  context.on('request', request => {
    const item = {caseId: spec.caseId, method: request.method(), url: request.url()};
    pageRequests.push(item);
    const parsed = new URL(request.url());
    const allowedProtocol = parsed.protocol === 'http:' || parsed.protocol === 'blob:' || parsed.protocol === 'about:';
    const allowedHost = ['127.0.0.1', 'localhost', '::1', '[::1]'].includes(parsed.hostname);
    if (!allowedProtocol || (parsed.protocol === 'http:' && !allowedHost)) {
      unexpectedPageRequests.push(item);
    }
  });
  const page = await context.newPage();
  page.on('pageerror', error => pageErrors.push(error.stack ?? error.message));
  page.on('console', message => consoleMessages.push({type: message.type(), text: message.text()}));
  page.on('dialog', async dialog => {
    dialogEvents.push({type: dialog.type(), message: dialog.message()});
    await dialog.accept();
  });

  let finalPage = page;
  let finalFrame = null;
  const snapshots = [];
  const navigationOutcomes = [];
  let reloadOutcome = null;
  let sourceDocument = null;
  const sourceGenerated = sourceHtmlFor(spec);
  try {
    const sourceResponse = await page.goto(sourceUrlFor(spec), {waitUntil: 'domcontentloaded', timeout: 10000});
    navigationOutcomes.push(outcomeFromResponse(sourceResponse, 'open-source'));
    sourceDocument = await snapshotDocument(page, 'source-before-interaction');
    snapshots.push(sourceDocument);

    if (spec.kind === 'opaque-frame') {
      await page.frameLocator('#opaque-frame').locator('#submit-form').waitFor({state: 'visible', timeout: 10000});
      finalFrame = page.frames().find(frame => frame !== page.mainFrame()) ?? null;
      assert.ok(finalFrame, 'sandbox srcdoc iframe should be present: ' + JSON.stringify(page.frames().map(frame => ({name: frame.name(), url: frame.url()}))));
      const nav = finalFrame.waitForNavigation({waitUntil: 'domcontentloaded', timeout: 10000});
      await page.frameLocator('#opaque-frame').locator('#submit-form').click();
      const response = await nav;
      navigationOutcomes.push(outcomeFromResponse(response, 'submit-opaque-post'));
      snapshots.push(await finalFrame.evaluate(() => ({
        label: 'opaque-frame-final',
        url: location.href,
        origin: location.origin,
        documentReferrer: document.referrer,
        documentReferrerPolicy: document.referrerPolicy ?? null,
        referrerObservation: (() => {
          try { return JSON.parse(document.querySelector('#referrer-observation')?.textContent ?? ''); }
          catch (_) { return null; }
        })(),
        title: document.title,
        bodyText: document.body?.innerText ?? '',
        performanceTimeOrigin: performance.timeOrigin,
        events: window.__originProbeEvents ?? [],
      })));
    } else if (spec.kind === 'named-target') {
      const popupPromise = page.waitForEvent('popup', {timeout: 10000});
      await page.locator('#open-named-target').click();
      finalPage = await popupPromise;
      finalPage.on('pageerror', error => pageErrors.push(error.stack ?? error.message));
      finalPage.on('console', message => consoleMessages.push({type: message.type(), text: message.text()}));
      await finalPage.waitForLoadState('domcontentloaded', {timeout: 10000});
      snapshots.push(await snapshotDocument(finalPage, 'named-target-after-get'));
      const nav = finalPage.waitForNavigation({waitUntil: 'domcontentloaded', timeout: 10000});
      await page.locator('#submit-form').click();
      const response = await nav;
      navigationOutcomes.push(outcomeFromResponse(response, 'source-a-post-to-named-target'));
      snapshots.push(await snapshotDocument(finalPage, 'named-target-after-source-post'));
    } else if (spec.kind === 'blob') {
      const blobNavigation = page.waitForNavigation({waitUntil: 'domcontentloaded', timeout: 10000});
      await page.locator('#blob-link').click();
      const blobResponse = await blobNavigation;
      navigationOutcomes.push(outcomeFromResponse(blobResponse, 'open-blob-document'));
      snapshots.push(await snapshotDocument(page, 'blob-document-before-post'));
      const nav = page.waitForNavigation({waitUntil: 'domcontentloaded', timeout: 10000});
      await page.locator('#submit-form').click();
      const response = await nav;
      navigationOutcomes.push(outcomeFromResponse(response, 'blob-creator-post'));
      snapshots.push(await snapshotDocument(page, 'blob-post-final'));
    } else if (spec.kind === 'anchor') {
      const nav = page.waitForNavigation({waitUntil: 'domcontentloaded', timeout: 10000});
      await page.locator('#navigate').click();
      const response = await nav;
      navigationOutcomes.push(outcomeFromResponse(response, 'click-get-link'));
      snapshots.push(await snapshotDocument(page, 'anchor-final'));
    } else {
      const nav = page.waitForNavigation({waitUntil: 'domcontentloaded', timeout: 10000});
      await page.locator('#submit-form').click();
      const response = await nav;
      navigationOutcomes.push(outcomeFromResponse(response, 'submit-form'));
      snapshots.push(await snapshotDocument(page, 'form-final'));

      if (spec.reloadAfterSubmit) {
        const beforeReloadRequestCount = requests.length;
        try {
          const reloadResponse = await page.reload({waitUntil: 'domcontentloaded', timeout: 10000});
          reloadOutcome = {
            completed: true,
            responseStatus: reloadResponse?.status() ?? null,
            responseUrl: reloadResponse?.url() ?? null,
            requestCountBefore: beforeReloadRequestCount,
            requestCountAfter: requests.length,
            newRequestCount: requests.length - beforeReloadRequestCount,
            dialogs: dialogEvents.slice(),
          };
          navigationOutcomes.push(outcomeFromResponse(reloadResponse, 'reload-post-result'));
          snapshots.push(await snapshotDocument(page, 'after-post-reload'));
        } catch (error) {
          reloadOutcome = {
            completed: false,
            error: error.stack ?? error.message,
            requestCountBefore: beforeReloadRequestCount,
            requestCountAfter: requests.length,
            newRequestCount: requests.length - beforeReloadRequestCount,
            dialogs: dialogEvents.slice(),
          };
          navigationErrors.push({step: 'reload-post-result', error: error.stack ?? error.message});
        }
      }
    }

    assert.deepEqual(unexpectedPageRequests, [], spec.caseId + ' must stay on synthetic loopback or blob/about documents.');
    const caseRequests = requests.slice(requestStart);
    const requestHops = caseRequests.filter(item =>
      item.caseId === spec.caseId && item.path !== '/source' && item.path !== '/favicon.ico',
    );
    const finalSnapshot = snapshots.at(-1) ?? null;
    const lastNavigationRequest = requestHops.at(-1) ?? null;
    const interaction = {
      kind: spec.kind,
      method: spec.method,
      actionUrl: actionUrlFor(spec),
      fields: ['form', 'reload', 'opaque-frame', 'blob', 'named-target'].includes(spec.kind) ? formFields(spec) : [],
      buttonLabel: spec.kind === 'opaque-frame'
        ? 'Submit opaque POST'
        : spec.method === 'POST' ? 'Submit POST' : 'Submit GET',
      linkText: spec.kind === 'anchor' ? 'Navigate with GET' : null,
      openBlobButtonLabel: spec.kind === 'blob' ? 'Open Blob form' : null,
      openNamedLinkText: spec.kind === 'named-target' ? 'Open named target' : null,
      namedInitialUrl: spec.kind === 'named-target' ? actionUrlForNamedInitial(spec) : null,
      targetName: spec.kind === 'named-target' ? 'origin-named-target' : null,
      referrerPolicyHeader: spec.headerPolicy ?? null,
      referrerPolicyMeta: spec.metaPolicy ?? null,
      referrerPolicyElement: spec.elementPolicy ?? null,
      formRel: spec.formRel ?? null,
      reloadAfterSubmit: Boolean(spec.reloadAfterSubmit),
      reloadFinalMetaPolicy: spec.finalMetaPolicy ?? null,
      opaqueFrameButtonLabel: spec.kind === 'opaque-frame' ? 'Submit opaque POST' : null,
      steps: spec.kind === 'anchor'
        ? [{action: 'tap-link', label: 'Navigate with GET'}]
        : spec.kind === 'blob'
          ? [{action: 'tap-link', label: 'Open Blob form'}, {action: 'tap-button', label: 'Submit POST'}]
          : spec.kind === 'named-target'
            ? [{action: 'tap-link', label: 'Open named target'}, {action: 'select-source'}, {action: 'tap-button', label: 'Submit POST'}]
            : spec.kind === 'reload'
              ? [{action: 'tap-button', label: 'Submit POST'}, {action: 'reload', label: 'Reload POST document'}]
              : [{action: 'tap-button', label: spec.kind === 'opaque-frame' ? 'Submit opaque POST' : spec.method === 'POST' ? 'Submit POST' : 'Submit GET'}],
    };
    const normalizedHops = requestHops.map(item => ({
      hop: requestHops.indexOf(item) + 1,
      server: item.server,
      serverOrigin: item.serverOrigin,
      method: item.method,
      url: item.url,
      path: item.path,
      body: item.body,
      origin: item.origin,
      requestOrigin: item.requestOrigin,
      requestOriginSource: item.requestOriginSource,
      referer: item.referer,
      authorization: item.authorization,
      authorizationPresent: item.authorizationPresent,
      responseStatus: item.responseStatus,
      responseLocation: item.responseLocation,
      responseReferrerPolicy: item.responseReferrerPolicy,
      responseOriginGuard: item.responseOriginGuard,
      responseGuardExpectedOrigin: item.responseGuardExpectedOrigin,
      responseBody: item.responseBody,
    }));
    const finalDocument = finalSnapshot ? {
      url: finalSnapshot.url,
      origin: finalSnapshot.origin,
      referrer: finalSnapshot.documentReferrer,
      documentReferrer: finalSnapshot.documentReferrer,
      documentReferrerPolicy: finalSnapshot.documentReferrerPolicy ?? null,
      referrerObservation: finalSnapshot.referrerObservation ?? null,
      requestOriginSource: lastNavigationRequest?.requestOriginSource ?? null,
      title: finalSnapshot.title,
      bodyText: finalSnapshot.bodyText,
      bodyGeneration: finalSnapshot.bodyGeneration ?? null,
      performanceTimeOrigin: finalSnapshot.performanceTimeOrigin,
      serverObservation: finalSnapshot.serverObservation ?? null,
      javascriptSnapshot: finalSnapshot,
    } : null;
    const result = {
      caseId: spec.caseId,
      kind: spec.kind,
      method: spec.method,
      targetOriginName: spec.targetOrigin,
      targetPath: spec.targetPath,
      sourceUrl: sourceUrlFor(spec),
      sourceHtml: sourceGenerated.html,
      embeddedHtml: sourceGenerated.embeddedHtml,
      interaction,
      sourceDocument,
      finalDocument,
      navigationOutcomes,
      reloadOutcome,
      guard: spec.guard ? {
        path: spec.targetPath,
        expectedOrigin: spec.guard === 'null' ? 'null' : originFor('a'),
        responseOriginGuard: requestHops.some(item => item.responseOriginGuard),
        responseStatus: requestHops.find(item => item.responseOriginGuard)?.responseStatus ?? null,
        accepted: requestHops.find(item => item.responseOriginGuard)?.responseStatus === 200,
      } : null,
      requests: caseRequests,
      requestHops: normalizedHops,
      snapshots,
      dialogs: dialogEvents,
      pageErrors,
      consoleMessages,
      navigationErrors,
      unexpectedPageRequests,
    };
    return normalizeFixtureValue(result);
  } finally {
    await context.close();
  }
}

const serverA = makeServer('a');
const serverB = makeServer('b');
const serverC = makeServer('c');
const nonForwardingProxy = createServer((request, response) => {
  proxyBlocked.push({method: request.method ?? '', protocol: request.headers['x-forwarded-proto'] ?? ''});
  response.writeHead(403, {'content-type': 'text/plain', connection: 'close'});
  response.end('This loopback-only proxy does not forward external requests.');
});
nonForwardingProxy.on('connect', (request, socket) => {
  proxyBlocked.push({method: 'CONNECT', protocol: 'https:'});
  socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n');
});

let browser = null;
try {
  origins.a = await listen(serverA, '127.0.0.1');
  origins.b = await listen(serverB, 'localhost');
  origins.c = await listen(serverC, '127.0.0.1');
  const proxyOrigin = await listen(nonForwardingProxy, '127.0.0.1');
  assert.notEqual(origins.a, origins.b);
  assert.notEqual(origins.b, origins.c);
  assert.notEqual(new URL(origins.a).hostname, new URL(origins.b).hostname);

  browser = await chromium.launch({
    headless: true,
    executablePath: browserExecutable,
    proxy: {
      server: proxyOrigin,
      bypass: '127.0.0.1,localhost,[::1]',
    },
    args: [
      '--disable-gpu',
      '--disable-background-networking',
      '--disable-component-update',
      '--disable-sync',
      '--no-first-run',
      '--no-default-browser-check',
    ],
  });

  const results = [];
  for (const spec of selectedCases) {
    results.push(await executeSpec(browser, spec));
  }

  const originGuardCase = results.find(item => item.caseId === 'post-origin-guard-cross-site');
  if (originGuardCase) {
    assert.equal(originGuardCase.guard?.responseStatus, 200, 'Origin guard must accept only the exact A Origin.');
    assert.equal(originGuardCase.guard?.accepted, true);
  }
  const opaqueGuardCase = results.find(item => item.caseId === 'post-opaque-sandbox-null-origin');
  if (opaqueGuardCase) {
    assert.ok(opaqueGuardCase.guard?.responseStatus === 200 || opaqueGuardCase.guard?.responseStatus === 403);
  }

  const commandLine = launchedChromeCommandLine();
  const disableBackForwardCacheFlagPresent = commandLine.includes('--disable-back-forward-cache');
  const blockedCountsByMethod = proxyBlocked.reduce((counts, item) => {
    counts[item.method] = (counts[item.method] ?? 0) + 1;
    return counts;
  }, {});
  const rawResults = normalizeFixtureValue(results);
  const fixturePath = process.env.PIRC_FIXTURE_PATH ??
    path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-origin-chromium153.json');
  const runnerBytes = await readFile(fileURLToPath(import.meta.url));
  const fixture = normalizeFixtureValue({
    browserVersion: browser.version(),
    browserExecutable: path.basename(browserExecutable),
    oracle: 'Dedicated Chromium 153 headless shell; actual navigations served only by three HTTP listeners bound to 127.0.0.1/localhost/127.0.0.1. Browser proxy is loopback-only and never forwards.',
    runner: 'apps/android/tool/parity/verify_document_origin_browser.mjs',
    runnerSha256: createHash('sha256').update(runnerBytes).digest('hex'),
    browserFlags: {
      disableBackForwardCacheFlagPresent,
      commandLineCaptured: Boolean(commandLine),
    },
    origins: {
      a: fixtureOriginFor('a'),
      b: fixtureOriginFor('b'),
      c: fixtureOriginFor('c'),
      siteRelation: 'A and C use 127.0.0.1 with distinct ports; B uses localhost. A/B/C are distinct origins; B is cross-site from A/C, while A/C are same-site but cross-origin.',
    },
    policyNames,
    caseCount: rawResults.length,
    cases: rawResults,
    serverRequests: normalizeFixtureValue(requests),
    externalProxy: {
      origin: normalizeOrigins(proxyOrigin),
      forwardsRequests: false,
      blockedRequestCount: proxyBlocked.length,
      blockedCountsByMethod,
      pageRequestsStayedOnLoopbackOrBlob: true,
    },
    scope: {
      tls: 'Not tested; all HTTP origins are loopback.',
      opaqueOrigins: 'Only a sandboxed srcdoc form navigation was observed; data: and sandbox escape cases were not tested.',
      downloads: 'Not tested.',
    },
  });
  await writeFile(fixturePath, JSON.stringify(fixture, null, 2) + '\n');
  process.stdout.write(JSON.stringify({
    browserVersion: fixture.browserVersion,
    fixturePath,
    runnerSha256: fixture.runnerSha256,
    caseCount: fixture.caseCount,
    requestCount: fixture.serverRequests.length,
    destinationHopCount: fixture.cases.reduce((sum, item) => sum + item.requestHops.length, 0),
    origins: fixture.origins,
    blockedProxyRequestCount: fixture.externalProxy.blockedRequestCount,
    disableBackForwardCacheFlagPresent,
    cases: fixture.cases.map(item => ({
      caseId: item.caseId,
      interaction: item.interaction.kind,
      hops: item.requestHops.map(hop => ({
        method: hop.method,
        path: hop.path,
        origin: hop.origin,
        requestOriginSource: hop.requestOriginSource,
        referer: hop.referer,
        status: hop.responseStatus,
        location: hop.responseLocation,
        body: hop.body,
      })),
      documentReferrer: item.finalDocument?.referrer ?? null,
      documentOrigin: item.finalDocument?.origin ?? null,
      reloadOutcome: item.reloadOutcome ? {
        completed: item.reloadOutcome.completed,
        newRequestCount: item.reloadOutcome.newRequestCount,
        dialogs: item.reloadOutcome.dialogs,
      } : null,
    })),
  }, null, 2) + '\n');
} finally {
  if (browser) await browser.close();
  await Promise.all([closeServer(serverA), closeServer(serverB), closeServer(serverC), closeServer(nonForwardingProxy)]);
}

