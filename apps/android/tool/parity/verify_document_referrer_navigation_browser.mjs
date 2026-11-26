import { requireTestBrowserExecutable } from './test_browser.mjs';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {createServer} from 'node:http';
import {copyFile, mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';

const scriptPath = fileURLToPath(import.meta.url);
const scriptDirectory = path.dirname(scriptPath);
const repositoryRoot = path.resolve(scriptDirectory, '../../../..');
const require = createRequire(import.meta.url);
const {chromium} = require(require.resolve('playwright-core', {
  paths: [path.join(repositoryRoot, 'apps/gateway')],
}));
const browserExecutable = requireTestBrowserExecutable();
const fixturePath = path.join(
  scriptDirectory,
  '../../../../packages/pirc_render/test/fixtures/parity/document-referrer-navigation-chromium153.json',
);
const evidenceDirectory = path.join(
  repositoryRoot,
  'apps/android/build/parity-acceptance/document-referrer-navigation-20261016',
);

const cases = [
  {caseId: 'form-get-same-origin', group: 'form', interaction: 'submit GET form to same origin'},
  {caseId: 'form-post-cross-origin', group: 'form', interaction: 'submit POST form to cross origin'},
  {caseId: 'form-rel-noreferrer-cross-origin', group: 'form', interaction: 'submit GET form with rel=noreferrer'},
  {caseId: 'form-referrerpolicy-no-referrer', group: 'form', interaction: 'submit GET form with referrerpolicy=no-referrer'},
  {caseId: 'location-assign-same-origin', group: 'location', interaction: 'user click calls location.assign'},
  {caseId: 'location-replace-cross-origin', group: 'location', interaction: 'user click calls location.replace'},
  {caseId: 'dynamic-meta-before-link', group: 'dynamic-meta', interaction: 'user click adds no-referrer meta, then clicks link'},
  {caseId: 'base-href-cross-origin-link', group: 'base-href', interaction: 'click relative link resolved through cross-origin base href'},
  {caseId: 'download-anchor-no-referrer', group: 'download', interaction: 'click same-origin download anchor with referrerpolicy=no-referrer'},
  {caseId: 'download-cross-origin-redirect', group: 'download', interaction: 'click same-origin download redirecting cross-origin'},
  {caseId: 'named-target-window', group: 'target', interaction: 'click link to a named browsing context'},
  {caseId: 'reload-after-link-navigation', group: 'reload', interaction: 'click link then reload destination'},
  {caseId: 'destination-meta-change-after-load', group: 'dynamic-meta', interaction: 'change destination meta after load, then click cross-origin link'},
  {caseId: 'back-forward-no-store', group: 'history', interaction: 'navigate, go back, then go forward with no-store responses'},
  {caseId: 'pushstate-query-before-link', group: 'history', interaction: 'pushState query update then click ordinary link'},
  {caseId: 'blob-document-http-link', group: 'blob', interaction: 'open Blob HTML then click ordinary HTTP link'},
];
const casesById = new Map(cases.map(item => [item.caseId, item]));
assert.equal(cases.length, 16);
assert.ok((await import('node:fs')).existsSync(browserExecutable),
  'The installed Google Chrome executable was not found.');

let sameOrigin = '';
let crossOrigin = '';
const requests = [];
const blockedRequests = [];
let requestSequence = 0;

function queryCaseId(url) {
  return url.searchParams.get('case') ?? '';
}

function targetUrl(caseId, cross = false, extra = {}) {
  const url = new URL('/target', cross ? crossOrigin : sameOrigin);
  url.searchParams.set('case', caseId);
  for (const [key, value] of Object.entries(extra)) url.searchParams.set(key, value);
  return url.href;
}

function sourceUrl(caseId) {
  const url = new URL('/source', sameOrigin);
  url.searchParams.set('case', caseId);
  return url.href;
}

function link(id, href, label, attributes = '') {
  return '<a id="' + id + '" href="' + href + '" ' + attributes + '>' + label + '</a>';
}

const lifecycleScript = '<script>' +
  'window.__oracleLifecycle=[{event:"document-start",url:location.href}];' +
  'for(const name of ["DOMContentLoaded","load","pagehide","pageshow"])' +
  '(name==="DOMContentLoaded"?document:window).addEventListener(name,event=>' +
  'window.__oracleLifecycle.push({event:name,persisted:Boolean(event.persisted),url:location.href}));' +
  '</script>';
const referrerSnapshotMarkup = '<pre id="referrer-observation"></pre><script>' +
  'document.addEventListener("DOMContentLoaded",()=>{' +
  'document.querySelector("#referrer-observation").textContent=' +
  'JSON.stringify({url:location.href,referrer:document.referrer});});' +
  '</script>';

function sourceHtml(spec) {
  const caseId = spec.caseId;
  const sameTarget = targetUrl(caseId);
  const crossTarget = targetUrl(caseId, true);
  let head = '<meta charset="utf-8"><title>Oracle source ' + caseId + '</title>';
  let body = '<h1>Oracle source ' + caseId + '</h1>';

  switch (caseId) {
    case 'form-get-same-origin':
      body += '<form id="navigate" action="' + sameOrigin + '/submit" method="get">' +
        '<input type="hidden" name="case" value="' + caseId + '">' +
        '<input name="payload" value="fixed-get-value"><button type="submit">Submit GET</button></form>';
      break;
    case 'form-post-cross-origin':
      body += '<form id="navigate" action="' + crossOrigin + '/submit?case=' + caseId + '" method="post">' +
        '<input name="payload" value="fixed-post-value"><button type="submit">Submit POST</button></form>';
      break;
    case 'form-rel-noreferrer-cross-origin':
      body += '<form id="navigate" rel="noreferrer" action="' + crossOrigin + '/target" method="get">' +
        '<input type="hidden" name="case" value="' + caseId + '">' +
        '<button type="submit">Submit noreferrer form</button></form>';
      break;
    case 'form-referrerpolicy-no-referrer':
      body += '<form id="navigate" referrerpolicy="no-referrer" action="' + crossOrigin + '/target" method="get">' +
        '<input type="hidden" name="case" value="' + caseId + '">' +
        '<button type="submit">Submit policy form</button></form>';
      break;
    case 'location-assign-same-origin':
      body += '<button id="navigate" onclick=\'location.assign("' + sameTarget + '")\'>Assign</button>';
      break;
    case 'location-replace-cross-origin':
      body += '<button id="navigate" onclick=\'location.replace("' + crossTarget + '")\'>Replace</button>';
      break;
    case 'dynamic-meta-before-link':
      body += '<button id="set-policy">Add no-referrer meta</button>' +
        '<script>document.querySelector("#set-policy").addEventListener("click",()=>{' +
        'const meta=document.createElement("meta");meta.name="referrer";meta.content="no-referrer";' +
        'document.head.append(meta);document.body.dataset.metaChanged="no-referrer";});</script>' +
        link('navigate', crossTarget, 'Follow link');
      break;
    case 'base-href-cross-origin-link':
      head = '<meta charset="utf-8"><base href="' + crossOrigin + '/">' +
        '<title>Oracle source ' + caseId + '</title>';
      body += link('navigate', 'target?case=' + caseId, 'Follow relative link');
      break;
    case 'download-anchor-no-referrer': {
      const url = new URL('/download', sameOrigin);
      url.searchParams.set('case', caseId);
      body += link('navigate', url.href, 'Download', 'download="oracle.txt" referrerpolicy="no-referrer"');
      break;
    }
    case 'download-cross-origin-redirect': {
      const url = new URL('/redirect/download', sameOrigin);
      url.searchParams.set('case', caseId);
      body += link('navigate', url.href, 'Download through redirect', 'download="oracle.txt"');
      break;
    }
    case 'named-target-window':
      body += link('navigate', crossTarget, 'Open named target', 'target="oracleNamedWindow"');
      break;
    case 'reload-after-link-navigation':
      body += link('navigate', sameTarget, 'Open reload destination');
      break;
    case 'destination-meta-change-after-load':
      body += link('navigate', sameTarget, 'Open destination with meta policy');
      break;
    case 'back-forward-no-store':
      body += link('navigate', crossTarget, 'Open history destination');
      break;
    case 'pushstate-query-before-link':
      body += '<button id="push-state">Change current query</button>' +
        '<script>document.querySelector("#push-state").addEventListener("click",()=>{' +
        'const url=new URL(location.href);url.searchParams.set("history","updated");' +
        'history.pushState({updated:true},"",url);});</script>' +
        link('navigate', crossTarget, 'Follow ordinary link');
      break;
    case 'blob-document-http-link': {
      const blobTarget = targetUrl(caseId, true);
      const html = '<!doctype html><html><head><meta charset="utf-8"><title>Blob source</title></head>' +
        '<body><h1>Blob source</h1>' + link('navigate', blobTarget, 'Follow HTTP link') +
        referrerSnapshotMarkup + '</body></html>';
      const embeddedHtml = JSON.stringify(html).replaceAll('</script>', '<\\/script>');
      body += '<button id="open-blob">Open Blob HTML</button><script>' +
        'document.querySelector("#open-blob").addEventListener("click",()=>{' +
        'const blob=new Blob([' + embeddedHtml + '],{type:"text/html"});' +
        'location.href=URL.createObjectURL(blob);});</script>';
      break;
    }
    default:
      throw new Error('No source page template for ' + caseId);
  }

  return '<!doctype html><html><head>' + lifecycleScript + head + '</head><body>' +
    body + referrerSnapshotMarkup + '</body></html>';
}

function destinationHtml(caseId, destination) {
  let meta = '';
  let body = '<h1>Oracle destination ' + caseId + '</h1>';
  if (caseId === 'destination-meta-change-after-load' && destination === 'initial') {
    meta = '<meta id="referrer-meta" name="referrer" content="no-referrer">';
    body += '<button id="change-meta">Change destination meta to unsafe-url</button>' +
      '<script>document.querySelector("#change-meta").addEventListener("click",()=>{' +
      'document.querySelector("#referrer-meta").content="unsafe-url";' +
      'document.body.dataset.metaChanged="unsafe-url";});</script>' +
      link('navigate', targetUrl(caseId, true, {stage: 'after-meta-change'}), 'Continue to cross origin');
  }
  const title = caseId === 'download-cross-origin-redirect' ? 'Downloaded final file' : 'Oracle destination ' + caseId;
  return '<!doctype html><html><head>' + lifecycleScript +
    '<meta charset="utf-8">' + meta + '<title>' + title + '</title></head><body>' +
    body + referrerSnapshotMarkup + '</body></html>';
}

function makeServer(serverName) {
  return createServer(async (request, response) => {
    const requestUrl = new URL(request.url ?? '/', serverName === 'same' ? sameOrigin : crossOrigin);
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    const body = Buffer.concat(chunks).toString('utf8');
    const caseId = queryCaseId(requestUrl);
    const event = {
      sequence: ++requestSequence,
      server: serverName,
      method: request.method ?? '',
      url: requestUrl.href,
      path: requestUrl.pathname,
      caseId,
      referer: request.headers.referer ?? null,
      origin: request.headers.origin ?? null,
      contentType: request.headers['content-type'] ?? null,
      secFetchSite: request.headers['sec-fetch-site'] ?? null,
      secFetchMode: request.headers['sec-fetch-mode'] ?? null,
      secFetchDest: request.headers['sec-fetch-dest'] ?? null,
      body: body || null,
      response: null,
    };
    requests.push(event);

    function reply(statusCode, headers, responseBody = '') {
      event.response = {
        statusCode,
        location: headers.location ?? null,
        referrerPolicy: headers['referrer-policy'] ?? null,
        contentType: headers['content-type'] ?? null,
        contentDisposition: headers['content-disposition'] ?? null,
        cacheControl: headers['cache-control'] ?? null,
        bodyText: responseBody,
      };
      response.writeHead(statusCode, headers);
      response.end(responseBody);
    }

    if (requestUrl.pathname === '/favicon.ico') {
      reply(204, {'cache-control': 'no-store'});
      return;
    }
    if (requestUrl.pathname === '/source' && serverName === 'same') {
      const spec = casesById.get(caseId);
      if (!spec) {
        reply(404, {}, 'unknown oracle case');
        return;
      }
      const responseHeaders = {
        'content-type': 'text/html; charset=utf-8',
        'cache-control': 'no-store',
      };
      if (['form-rel-noreferrer-cross-origin', 'form-referrerpolicy-no-referrer',
        'dynamic-meta-before-link', 'base-href-cross-origin-link', 'download-anchor-no-referrer',
        'location-assign-same-origin', 'location-replace-cross-origin',
        'pushstate-query-before-link', 'blob-document-http-link'].includes(caseId)) {
        responseHeaders['referrer-policy'] = 'unsafe-url';
      }
      reply(200, responseHeaders, sourceHtml(spec));
      return;
    }
    if (requestUrl.pathname === '/redirect/download' && serverName === 'same') {
      reply(302, {
        'cache-control': 'no-store',
        location: crossOrigin + '/download?case=' + encodeURIComponent(caseId) + '&stage=final',
      });
      return;
    }
    if (requestUrl.pathname === '/download') {
      reply(200, {
        'content-type': 'application/octet-stream',
        'content-disposition': 'attachment; filename="oracle.txt"',
        'cache-control': 'no-store',
      }, 'loopback referrer oracle download\n');
      return;
    }
    if ((requestUrl.pathname === '/target' || requestUrl.pathname === '/submit') &&
        (serverName === 'same' || serverName === 'cross')) {
      reply(200, {
        'content-type': 'text/html; charset=utf-8',
        'cache-control': 'no-store',
      }, destinationHtml(caseId, requestUrl.searchParams.get('stage') ?? 'initial'));
      return;
    }
    reply(404, {
      'content-type': 'text/plain; charset=utf-8',
      'cache-control': 'no-store',
    }, 'unknown loopback oracle path');
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
  if (server.listening) await new Promise(resolve => server.close(resolve));
}

function attachPageErrorCapture(page, errors, pageLabel) {
  page.on('pageerror', error => errors.push({page: pageLabel, type: 'pageerror', message: error.message}));
  page.on('console', message => {
    if (message.type() === 'error') {
      errors.push({page: pageLabel, type: 'console-error', message: message.text()});
    }
  });
}

async function snapshot(page, label) {
  return page.evaluate(labelValue => ({
    label: labelValue,
    url: location.href,
    documentReferrer: document.referrer,
    referrerObservation: (() => {
      const text = document.querySelector('#referrer-observation')?.textContent ?? '';
      try { return JSON.parse(text); } catch (_) { return null; }
    })(),
    title: document.title,
    referrerMeta: document.querySelector('meta[name="referrer"]')?.content ?? null,
    baseHref: document.querySelector('base')?.href ?? null,
    bodyMetaChanged: document.body.dataset.metaChanged ?? null,
    lifecycle: window.__oracleLifecycle ?? [],
  }), label);
}

async function clickNavigation(page, selector) {
  const navigation = page.waitForNavigation({waitUntil: 'domcontentloaded', timeout: 10000});
  await page.locator(selector).click();
  const response = await navigation;
  return response?.url() ?? page.url();
}

async function runCase(browser, spec) {
  const requestStart = requests.length;
  const errors = [];
  const snapshots = [];
  const actions = [];
  const downloadEvents = [];
  const context = await browser.newContext();
  let pageSequence = 0;
  context.on('page', page => attachPageErrorCapture(page, errors, 'page-' + (++pageSequence)));
  await context.route('**/*', async route => {
    const requested = new URL(route.request().url());
    const localPort = [new URL(sameOrigin).port, new URL(crossOrigin).port].includes(requested.port);
    const localHttp = requested.protocol === 'http:' && requested.hostname === '127.0.0.1' && localPort;
    const localBlob = requested.protocol === 'blob:' &&
      [new URL(sameOrigin).origin, new URL(crossOrigin).origin].includes(requested.origin);
    if (localHttp || localBlob) {
      await route.continue();
    } else {
      blockedRequests.push({caseId: spec.caseId, url: requested.href});
      await route.abort();
    }
  });
  const page = await context.newPage();
  try {
    await page.goto(sourceUrl(spec.caseId), {waitUntil: 'domcontentloaded'});
    actions.push({action: 'load-source', url: page.url()});
    snapshots.push(await snapshot(page, 'source-loaded'));

    switch (spec.caseId) {
      case 'form-get-same-origin':
      case 'form-post-cross-origin':
      case 'form-rel-noreferrer-cross-origin':
      case 'form-referrerpolicy-no-referrer':
        actions.push({
          action: 'form-attributes',
          rel: await page.locator('#navigate').getAttribute('rel'),
          referrerpolicy: await page.locator('#navigate').getAttribute('referrerpolicy'),
        });
        actions.push({action: 'submit-form', method: spec.caseId.includes('post') ? 'POST' : 'GET'});
        actions.push({action: 'navigation-result', url: await clickNavigation(page, '#navigate button')});
        snapshots.push(await snapshot(page, 'form-destination'));
        break;
      case 'location-assign-same-origin':
      case 'location-replace-cross-origin':
        actions.push({action: spec.caseId.includes('assign') ? 'click-location-assign' : 'click-location-replace'});
        actions.push({action: 'navigation-result', url: await clickNavigation(page, '#navigate')});
        snapshots.push(await snapshot(page, 'location-destination'));
        break;
      case 'dynamic-meta-before-link':
        await page.locator('#set-policy').click();
        actions.push({action: 'click-add-referrer-meta', meta: await page.locator('meta[name="referrer"]').getAttribute('content')});
        snapshots.push(await snapshot(page, 'source-after-dynamic-meta'));
        actions.push({action: 'click-link', url: await clickNavigation(page, '#navigate')});
        snapshots.push(await snapshot(page, 'link-destination'));
        break;
      case 'base-href-cross-origin-link':
        actions.push({action: 'click-relative-link', baseHref: await page.locator('base').getAttribute('href')});
        actions.push({action: 'navigation-result', url: await clickNavigation(page, '#navigate')});
        snapshots.push(await snapshot(page, 'link-destination'));
        break;
      case 'download-anchor-no-referrer':
      case 'download-cross-origin-redirect': {
        const downloadWait = page.waitForEvent('download', {timeout: 10000});
        await page.locator('#navigate').click();
        const download = await downloadWait;
        downloadEvents.push({
          suggestedFilename: download.suggestedFilename(),
          failure: await download.failure(),
        });
        actions.push({action: 'click-download', pageUrlAfterClick: page.url()});
        snapshots.push(await snapshot(page, 'source-after-download'));
        break;
      }
      case 'named-target-window': {
        const popupWait = page.waitForEvent('popup', {timeout: 10000});
        await page.locator('#navigate').click();
        const popup = await popupWait;
        await popup.waitForLoadState('domcontentloaded');
        actions.push({action: 'click-named-target', popupUrl: popup.url()});
        snapshots.push(await snapshot(popup, 'named-target-document'));
        break;
      }
      case 'reload-after-link-navigation':
        actions.push({action: 'click-link', url: await clickNavigation(page, '#navigate')});
        snapshots.push(await snapshot(page, 'destination-before-reload'));
        await page.reload({waitUntil: 'domcontentloaded'});
        actions.push({action: 'reload', url: page.url()});
        snapshots.push(await snapshot(page, 'destination-after-reload'));
        break;
      case 'destination-meta-change-after-load':
        actions.push({action: 'click-source-link', url: await clickNavigation(page, '#navigate')});
        snapshots.push(await snapshot(page, 'destination-before-meta-change'));
        await page.locator('#change-meta').click();
        actions.push({action: 'click-change-destination-meta', meta: await page.locator('meta[name="referrer"]').getAttribute('content')});
        snapshots.push(await snapshot(page, 'destination-after-meta-change'));
        actions.push({action: 'click-cross-origin-link', url: await clickNavigation(page, '#navigate')});
        snapshots.push(await snapshot(page, 'cross-origin-destination'));
        break;
      case 'back-forward-no-store':
        actions.push({action: 'click-link', url: await clickNavigation(page, '#navigate')});
        snapshots.push(await snapshot(page, 'history-target-before-back'));
        actions.push({action: 'go-back', result: await page.goBack({waitUntil: 'domcontentloaded', timeout: 10000})?.then(response => response.url()) ?? null});
        snapshots.push(await snapshot(page, 'history-source-after-back'));
        actions.push({action: 'go-forward', result: await page.goForward({waitUntil: 'domcontentloaded', timeout: 10000})?.then(response => response.url()) ?? null});
        snapshots.push(await snapshot(page, 'history-target-after-forward'));
        break;
      case 'pushstate-query-before-link':
        await page.locator('#push-state').click();
        actions.push({action: 'click-pushState', updatedUrl: page.url()});
        snapshots.push(await snapshot(page, 'source-after-pushState'));
        actions.push({action: 'click-ordinary-link', url: await clickNavigation(page, '#navigate')});
        snapshots.push(await snapshot(page, 'link-destination'));
        break;
      case 'blob-document-http-link': {
        const blobNavigation = page.waitForURL(url => url.href.startsWith('blob:'), {
          waitUntil: 'domcontentloaded',
          timeout: 10000,
        });
        await page.locator('#open-blob').click();
        await blobNavigation;
        actions.push({action: 'open-blob-document', url: page.url()});
        snapshots.push(await snapshot(page, 'blob-document-before-http-link'));
        actions.push({action: 'click-http-link-from-blob', url: await clickNavigation(page, '#navigate')});
        snapshots.push(await snapshot(page, 'http-destination-from-blob'));
        break;
      }
      default:
        throw new Error('No runner steps for ' + spec.caseId);
    }
  } finally {
    await context.close();
  }

  return {
    ...spec,
    sourceUrl: sourceUrl(spec.caseId),
    sourceHtml: sourceHtml(spec),
    actions,
    snapshots,
    downloadEvents,
    pageErrors: errors,
    requests: requests.slice(requestStart),
  };
}

let browser = null;
try {
  sameOrigin = await listen(sameServer);
  crossOrigin = await listen(crossServer);
  assert.notEqual(sameOrigin, crossOrigin);
  browser = await chromium.launch({
    headless: true,
    executablePath: browserExecutable,
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
  for (const spec of cases) results.push(await runCase(browser, spec));
  assert.deepEqual(blockedRequests, [], 'The browser attempted traffic outside the loopback oracle.');

  const runnerSource = await readFile(scriptPath);
  const fixture = {
    browserVersion: browser.version(),
    browserExecutable: path.basename(browserExecutable),
    generatedAt: new Date().toISOString(),
    oracle: 'Dedicated Chromium 153 headless shell; all navigations and download responses served on two 127.0.0.1 loopback origins; non-local browser requests are blocked.',
    runner: 'apps/android/tool/parity/verify_document_referrer_navigation_browser.mjs',
    runnerSha256: createHash('sha256').update(runnerSource).digest('hex'),
    origins: {sameOrigin, crossOrigin},
    caseCount: results.length,
    cases: results,
    serverRequests: requests,
    blockedRequests,
  };
  const fixtureBytes = JSON.stringify(fixture, null, 2) + '\n';
  await writeFile(fixturePath, fixtureBytes);
  await mkdir(evidenceDirectory, {recursive: true});
  const evidenceRunnerPath = path.join(evidenceDirectory, 'verify_document_referrer_navigation_browser.mjs');
  const evidenceFixturePath = path.join(evidenceDirectory, 'document-referrer-navigation-chromium153.json');
  await copyFile(scriptPath, evidenceRunnerPath);
  await writeFile(evidenceFixturePath, fixtureBytes);
  const fixtureSha256 = createHash('sha256').update(fixtureBytes).digest('hex');
  await writeFile(path.join(evidenceDirectory, 'SHA256SUMS'),
    fixture.runnerSha256 + '  verify_document_referrer_navigation_browser.mjs\n' +
    fixtureSha256 + '  document-referrer-navigation-chromium153.json\n');
  await writeFile(path.join(evidenceDirectory, 'README.md'),
    '# Chrome document referrer navigation oracle\n\n' +
    'Captured with dedicated Chromium 153 on ' + fixture.generatedAt + '.\n' +
    'The runner uses two loopback HTTP origins and blocks requests outside those listeners.\n' +
    'The JSON stores raw server request headers, navigation actions, document.referrer snapshots, ' +
    'download events, browser lifecycle events, and page errors.\n\n' +
    'Run from the repository root with `/opt/homebrew/bin/node apps/android/tool/parity/verify_document_referrer_navigation_browser.mjs`.\n');

  process.stdout.write(JSON.stringify({
    browserVersion: browser.version(),
    caseCount: results.length,
    fixturePath,
    evidenceDirectory,
    runnerSha256: fixture.runnerSha256,
    fixtureSha256,
    blockedRequestCount: blockedRequests.length,
    caseSummaries: results.map(item => ({
      caseId: item.caseId,
      requests: item.requests.filter(request => request.path !== '/source' && request.path !== '/favicon.ico')
        .map(request => ({method: request.method, path: request.path, referer: request.referer})),
      documentReferrers: item.snapshots.map(snapshotValue => ({
        label: snapshotValue.label,
        referrer: snapshotValue.documentReferrer,
        url: snapshotValue.url,
      })),
      pageErrors: item.pageErrors,
    })),
  }, null, 2) + '\n');
} finally {
  if (browser) await browser.close();
  await Promise.all([closeServer(sameServer), closeServer(crossServer)]);
}
