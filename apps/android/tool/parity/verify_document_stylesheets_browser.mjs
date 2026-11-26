import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {createServer} from 'node:http';
import {createRequire} from 'node:module';
import {readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {requireTestBrowserExecutable} from './test_browser.mjs';

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(scriptDirectory, '../../../..');
const require = createRequire(import.meta.url);
const {chromium} = require(require.resolve('playwright-core', {
  paths: [path.join(repositoryRoot, 'apps/gateway')],
}));
const browserExecutable = requireTestBrowserExecutable();
assert.ok(!browserExecutable.includes('/Applications/Google Chrome.app/'));
assert.ok(browserExecutable.includes('/.pirc/test-browsers/'));
const fixturePath = path.join(scriptDirectory, '../../../../packages/pirc_render/test/fixtures/parity/document-stylesheets-chromium153.json');
let priorFixture = null;
try {
  priorFixture = JSON.parse(await readFile(fixturePath, 'utf8'));
} catch (error) {
  if (error?.code !== 'ENOENT') throw error;
}

const fixtureOrigins = {
  a: 'http://127.0.0.1:43100',
  b: 'http://localhost:43100',
};
let originA = '';
let originB = '';
const serverRequests = [];
const pageRequests = [];
const blockedPageRequests = [];
const blockedProxyRequests = [];
const runnerStart = performance.now();

const pageMarkup = [
  'inlineProbe', 'mediaProbe', 'linkProbe', 'baseProbe', 'externalProbe',
  'importProbe', 'orderProbe', 'crossProbe', 'corsProbe',
].map(id => `<div id="${id}">${id}</div>`).join('\n');

function htmlDocument(caseId) {
  return '<!doctype html><html><head><meta charset="utf-8"><title>stylesheet oracle ' +
    String(caseId).replaceAll('<', '&lt;') + '</title></head><body>' + pageMarkup + '</body></html>';
}

function responseBody(pathname, requestUrl) {
  if (pathname === '/page') {
    return {status: 200, contentType: 'text/html; charset=utf-8', body: htmlDocument(requestUrl.searchParams.get('case') ?? 'page')};
  }
  if (pathname === '/css/link-a.css') {
    return {status: 200, contentType: 'text/css; charset=utf-8', body: '#linkProbe { color: rgb(201, 0, 0); width: 11px; height: 9px; }'};
  }
  if (pathname === '/css/link-b.css') {
    return {status: 200, contentType: 'text/css; charset=utf-8', body: '#linkProbe { color: rgb(0, 201, 0); width: 22px; height: 12px; }'};
  }
  if (pathname === '/css/link-slow.css') {
    return {status: 200, contentType: 'text/css; charset=utf-8', delayMs: 450,
      body: '#linkProbe { color: rgb(0, 33, 201); width: 33px; height: 15px; }'};
  }
  if (pathname === '/css/root-import-fail-404.css') {
    return {status: 200, contentType: 'text/css; charset=utf-8',
      body: `@import url('/css/import-fail-404.css?case=import-fail-404');\n#importProbe { color: rgb(120, 0, 0); width: 33px; height: 16px; }`};
  }
  if (pathname === '/css/root-import-fail-mime.css') {
    return {status: 200, contentType: 'text/css; charset=utf-8',
      body: `@import url('/css/import-fail-mime.css?case=import-fail-mime');\n#importProbe { color: rgb(120, 0, 0); width: 33px; height: 16px; }`};
  }
  if (pathname === '/css/import-fail-404.css') {
    return {status: 404, contentType: 'text/plain; charset=utf-8', delayMs: 90, body: 'synthetic imported stylesheet missing'};
  }
  if (pathname === '/css/import-fail-mime.css') {
    return {status: 200, contentType: 'text/plain; charset=utf-8', delayMs: 90,
      body: '#importProbe { color: rgb(0, 120, 0); width: 51px; }'};
  }
  if (pathname === '/css/inline-style-import.css') {
    return {status: 200, contentType: 'text/css; charset=utf-8', delayMs: 160,
      body: '#importProbe { color: rgb(0, 0, 120); height: 27px; }'};
  }
  if (pathname === '/css/disabled-link.css') {
    return {status: 200, contentType: 'text/css; charset=utf-8', delayMs: 160,
      body: '#linkProbe { color: rgb(123, 45, 67); width: 38px; height: 24px; }'};
  }
  if (pathname === '/css/primary.css') {
    return {
      status: 200,
      contentType: 'text/css; charset=utf-8',
      body: `@import url('/css/imported.css?case=css-import');
#externalProbe { color: rgb(7, 8, 9); width: 35px; height: 19px; background-image: url('../assets/texture.svg?case=css-relative-asset'); }
#importProbe { color: rgb(210, 0, 0); width: 29px; }
#orderProbe { color: rgb(200, 0, 0); width: 31px; }`,
    };
  }
  if (pathname === '/css/imported.css') {
    return {
      status: 200,
      contentType: 'text/css; charset=utf-8',
      delayMs: 140,
      body: `#importProbe { color: rgb(0, 0, 210); height: 43px; }
#orderProbe { color: rgb(0, 0, 200); }`,
    };
  }
  if (pathname === '/css/order-later.css') {
    return {status: 200, contentType: 'text/css; charset=utf-8', body: '#orderProbe { color: rgb(0, 170, 0); }'};
  }
  if (pathname === '/assets/texture.svg') {
    return {
      status: 200,
      contentType: 'image/svg+xml',
      body: '<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"><rect width="4" height="4" fill="#123456"/></svg>',
    };
  }
  if (pathname === '/base/one/styles.css') {
    return {status: 200, contentType: 'text/css; charset=utf-8', body: '#baseProbe { color: rgb(145, 0, 0); width: 41px; height: 13px; }'};
  }
  if (pathname === '/base/two/styles.css') {
    return {status: 200, contentType: 'text/css; charset=utf-8', body: '#baseProbe { color: rgb(0, 0, 145); width: 52px; height: 17px; }'};
  }
  if (pathname === '/css/cross.css') {
    return {status: 200, contentType: 'text/css; charset=utf-8', body: '#crossProbe { color: rgb(44, 55, 66); width: 37px; height: 21px; }'};
  }
  if (pathname === '/css/cors.css') {
    return {
      status: 200,
      contentType: 'text/css; charset=utf-8',
      headers: {'access-control-allow-origin': '*', vary: 'Origin'},
      body: '#corsProbe { color: rgb(66, 55, 44); width: 47px; height: 26px; }',
    };
  }
  if (pathname === '/css/missing.css') {
    return {status: 404, contentType: 'text/plain; charset=utf-8', body: 'synthetic missing stylesheet'};
  }
  return {status: 404, contentType: 'text/plain; charset=utf-8', body: 'unexpected local stylesheet-oracle request'};
}

function makeServer() {
  return createServer(async (request, response) => {
    const hostHeader = request.headers.host ?? '';
    const requestUrl = new URL(request.url ?? '/', 'http://' + hostHeader);
    const spec = responseBody(requestUrl.pathname, requestUrl);
    const event = {
      sequence: serverRequests.length + 1,
      elapsedMs: Number((performance.now() - runnerStart).toFixed(1)),
      method: request.method ?? '',
      hostname: requestUrl.hostname,
      path: requestUrl.pathname + requestUrl.search,
      url: requestUrl.href,
      origin: request.headers.origin ?? null,
      referer: request.headers.referer ?? null,
      authorizationPresent: Boolean(request.headers.authorization),
      secFetchSite: request.headers['sec-fetch-site'] ?? null,
      secFetchMode: request.headers['sec-fetch-mode'] ?? null,
      secFetchDest: request.headers['sec-fetch-dest'] ?? null,
      responseStatus: spec.status,
      responseContentType: spec.contentType,
    };
    serverRequests.push(event);
    request.resume();
    const send = () => {
      response.writeHead(spec.status, {
        'cache-control': 'no-store',
        'content-type': spec.contentType,
        ...spec.headers,
      });
      response.end(spec.body);
    };
    if (spec.delayMs) setTimeout(send, spec.delayMs);
    else send();
  });
}

const server = makeServer();
const nonForwardingProxy = createServer((request, response) => {
  blockedProxyRequests.push({method: request.method ?? ''});
  response.writeHead(403, {'content-type': 'text/plain; charset=utf-8', connection: 'close'});
  response.end('This loopback-only Chromium proxy never forwards requests.');
});
nonForwardingProxy.on('connect', (request, socket) => {
  blockedProxyRequests.push({method: 'CONNECT'});
  socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n');
});

async function listen(target, host, port = 0) {
  await new Promise((resolve, reject) => {
    target.once('error', reject);
    target.listen(port, host, () => {
      target.off('error', reject);
      resolve();
    });
  });
  const address = target.address();
  assert.ok(address && typeof address === 'object');
  return address.port;
}

async function closeServer(target) {
  if (target.closeAllConnections) target.closeAllConnections();
  if (target.listening) await new Promise(resolve => target.close(resolve));
}

function isSyntheticLoopbackUrl(rawUrl) {
  const url = new URL(rawUrl);
  return url.protocol === 'http:' && ['127.0.0.1', 'localhost'].includes(url.hostname);
}

function normalizeText(value, actualPort, proxyPort) {
  return String(value)
    .replaceAll('http://127.0.0.1:' + actualPort, fixtureOrigins.a)
    .replaceAll('http://localhost:' + actualPort, fixtureOrigins.b)
    .replaceAll('http://127.0.0.1:' + proxyPort, 'http://127.0.0.1:43199');
}

function normalize(value, actualPort, proxyPort) {
  if (typeof value === 'string') return normalizeText(value, actualPort, proxyPort);
  if (Array.isArray(value)) return value.map(item => normalize(item, actualPort, proxyPort));
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, normalize(item, actualPort, proxyPort)]));
  }
  return value;
}

async function sleep(milliseconds) {
  await new Promise(resolve => setTimeout(resolve, milliseconds));
}

async function waitUntil(predicate, timeoutMs = 5000, intervalMs = 10) {
  const endAt = Date.now() + timeoutMs;
  while (Date.now() <= endAt) {
    if (await predicate()) return true;
    await sleep(intervalMs);
  }
  return false;
}

async function makePage(context, caseId) {
  const page = await context.newPage();
  page.on('request', request => pageRequests.push({
    url: request.url(),
    method: request.method(),
    resourceType: request.resourceType(),
  }));
  await page.goto(originA + '/page?case=' + encodeURIComponent(caseId), {waitUntil: 'load'});
  return page;
}

async function styleSnapshot(page, id) {
  return page.evaluate(targetId => {
    const element = document.getElementById(targetId);
    const style = getComputedStyle(element);
    const rect = element.getBoundingClientRect();
    return {
      color: style.color,
      backgroundColor: style.backgroundColor,
      backgroundImage: style.backgroundImage,
      display: style.display,
      width: style.width,
      height: style.height,
      marginLeft: style.marginLeft,
      rectWidth: Number(rect.width.toFixed(2)),
      rectHeight: Number(rect.height.toFixed(2)),
    };
  }, id);
}

async function appendLinkAndWait(page, id, href, options = {}) {
  const beforeCount = await page.evaluate(() => window.__stylesheetEvents?.length ?? 0);
  await page.evaluate(({id, href, crossOrigin}) => {
    window.__stylesheetEvents ??= [];
    const link = document.createElement('link');
    link.id = id;
    link.rel = 'stylesheet';
    if (crossOrigin !== undefined) link.crossOrigin = crossOrigin;
    link.addEventListener('load', () => window.__stylesheetEvents.push({
      id,
      type: 'load',
      elapsedMs: Number(performance.now().toFixed(2)),
      href: link.href,
      sheetHref: link.sheet?.href ?? null,
      ruleCount: (() => { try { return link.sheet?.cssRules.length ?? null; } catch { return null; } })(),
    }));
    link.addEventListener('error', () => window.__stylesheetEvents.push({
      id,
      type: 'error',
      elapsedMs: Number(performance.now().toFixed(2)),
      href: link.href,
      sheetHref: link.sheet?.href ?? null,
      ruleCount: (() => { try { return link.sheet?.cssRules.length ?? null; } catch { return null; } })(),
    }));
    link.href = href;
    document.head.append(link);
    window.__stylesheetLinks ??= {};
    window.__stylesheetLinks[id] = link;
  }, {id, href, crossOrigin: options.crossOrigin});
  const count = beforeCount + 1;
  await page.waitForFunction(expected => window.__stylesheetEvents?.length >= expected, count, {timeout: 5000});
  return page.evaluate(({id, count}) => ({
    events: window.__stylesheetEvents.slice(count - 1),
    link: (() => {
      const link = window.__stylesheetLinks[id];
      let cssRules;
      let error = null;
      try { cssRules = Array.from(link.sheet?.cssRules ?? [], rule => rule.cssText); }
      catch (exception) { error = {name: exception?.name ?? 'Error', message: exception?.message ?? String(exception)}; }
      return {
        hrefAttribute: link.getAttribute('href'),
        href: link.href,
        crossOrigin: link.crossOrigin || null,
        sheetPresent: link.sheet != null,
        sheetHref: link.sheet?.href ?? null,
        disabled: link.disabled,
        media: link.media,
        cssRules,
        cssRulesError: error,
      };
    })(),
  }), {id, count});
}

let browser = null;
let context = null;
const ownedPages = new Set();
try {
  const actualPort = await listen(server, '127.0.0.1');
  originA = 'http://127.0.0.1:' + actualPort;
  originB = 'http://localhost:' + actualPort;
  const proxyPort = await listen(nonForwardingProxy, '127.0.0.1');
  browser = await chromium.launch({
    headless: true,
    executablePath: browserExecutable,
    proxy: {
      server: 'http://127.0.0.1:' + proxyPort,
      bypass: 'localhost,127.0.0.1,[::1]',
    },
    args: [
      '--disable-background-networking',
      '--disable-component-update',
      '--disable-sync',
      '--no-first-run',
      '--no-default-browser-check',
      '--host-resolver-rules=MAP localhost 127.0.0.1',
    ],
  });
  assert.match(browser.version(), /^153\./, 'This fixture must use the dedicated Chromium 153 test shell');
  context = await browser.newContext();
  await context.route('**/*', async route => {
    const requestUrl = route.request().url();
    if (isSyntheticLoopbackUrl(requestUrl)) {
      await route.continue();
      return;
    }
    blockedPageRequests.push({method: route.request().method(), url: requestUrl});
    await route.abort();
  });

  const cssomPage = await makePage(context, 'inline-cssom');
  ownedPages.add(cssomPage);
  const cssom = await cssomPage.evaluate(() => {
    const style = document.createElement('style');
    style.id = 'dynamic-inline-style';
    style.textContent = '#inlineProbe { color: rgb(1, 2, 3); width: 10px; height: 12px; }';
    document.head.append(style);
    const sheetBefore = style.sheet;
    const initial = {
      sheetPresent: sheetBefore != null,
      href: sheetBefore?.href ?? null,
      ruleCount: sheetBefore?.cssRules.length ?? null,
      target: (() => {
        const computed = getComputedStyle(document.querySelector('#inlineProbe'));
        const rect = document.querySelector('#inlineProbe').getBoundingClientRect();
        return {color: computed.color, width: computed.width, height: computed.height,
          rectWidth: Number(rect.width.toFixed(2)), rectHeight: Number(rect.height.toFixed(2))};
      })(),
    };
    const insertedIndex = sheetBefore.insertRule('#inlineProbe { color: rgb(9, 19, 29); width: 31px; height: 17px; }', sheetBefore.cssRules.length);
    const insertedRule = sheetBefore.cssRules[insertedIndex];
    const afterInsert = {
      insertedIndex,
      cssText: insertedRule.cssText,
      target: (() => {
        const computed = getComputedStyle(document.querySelector('#inlineProbe'));
        const rect = document.querySelector('#inlineProbe').getBoundingClientRect();
        return {color: computed.color, width: computed.width, height: computed.height,
          rectWidth: Number(rect.width.toFixed(2)), rectHeight: Number(rect.height.toFixed(2))};
      })(),
    };
    insertedRule.style.setProperty('color', 'rgb(4, 5, 6)');
    insertedRule.style.setProperty('height', '23px');
    const afterSetProperty = {
      cssText: insertedRule.cssText,
      inlineStyleLength: insertedRule.style.length,
      colorPriority: insertedRule.style.getPropertyPriority('color'),
      target: (() => {
        const computed = getComputedStyle(document.querySelector('#inlineProbe'));
        const rect = document.querySelector('#inlineProbe').getBoundingClientRect();
        return {color: computed.color, width: computed.width, height: computed.height,
          rectWidth: Number(rect.width.toFixed(2)), rectHeight: Number(rect.height.toFixed(2))};
      })(),
    };
    sheetBefore.deleteRule(insertedIndex);
    const afterDelete = {
      ruleCount: sheetBefore.cssRules.length,
      cssText: sheetBefore.cssRules[0]?.cssText ?? null,
      target: (() => {
        const computed = getComputedStyle(document.querySelector('#inlineProbe'));
        const rect = document.querySelector('#inlineProbe').getBoundingClientRect();
        return {color: computed.color, width: computed.width, height: computed.height,
          rectWidth: Number(rect.width.toFixed(2)), rectHeight: Number(rect.height.toFixed(2))};
      })(),
    };
    style.textContent = '#inlineProbe { color: rgb(17, 27, 37); width: 41px; height: 19px; }';
    const afterTextReset = {
      sameSheetObject: style.sheet === sheetBefore,
      ruleCount: style.sheet?.cssRules.length ?? null,
      cssText: style.sheet?.cssRules[0]?.cssText ?? null,
      target: (() => {
        const computed = getComputedStyle(document.querySelector('#inlineProbe'));
        const rect = document.querySelector('#inlineProbe').getBoundingClientRect();
        return {color: computed.color, width: computed.width, height: computed.height,
          rectWidth: Number(rect.width.toFixed(2)), rectHeight: Number(rect.height.toFixed(2))};
      })(),
    };
    return {initial, afterInsert, afterSetProperty, afterDelete, afterTextReset};
  });
  assert.equal(cssom.afterInsert.target.color, 'rgb(9, 19, 29)');
  assert.equal(cssom.afterSetProperty.target.color, 'rgb(4, 5, 6)');
  assert.equal(cssom.afterDelete.target.color, 'rgb(1, 2, 3)');
  assert.equal(cssom.afterTextReset.target.color, 'rgb(17, 27, 37)');
  const cssomCase = {
    caseId: 'inline-cssom-mutations',
    source: 'Actual inline HTMLStyleElement.sheet insertRule, CSSStyleRule.style.setProperty, deleteRule, and style.textContent reset observations with computed colors and dimensions.',
    result: cssom,
  };

  const mediaPage = await makePage(context, 'media-disabled');
  ownedPages.add(mediaPage);
  const media = await mediaPage.evaluate(() => {
    const style = document.createElement('style');
    style.id = 'conditional-style';
    style.media = '(min-width: 99999px)';
    style.textContent = '#mediaProbe { color: rgb(99, 1, 2); width: 42px; height: 18px; }';
    document.head.append(style);
    const snapshot = label => {
      const computed = getComputedStyle(document.querySelector('#mediaProbe'));
      const rect = document.querySelector('#mediaProbe').getBoundingClientRect();
      return {
        label,
        mediaAttribute: style.media,
        mediaText: style.sheet.media.mediaText,
        matchesQuery: matchMedia(style.sheet.media.mediaText).matches,
        styleDisabled: style.disabled,
        sheetDisabled: style.sheet.disabled,
        color: computed.color,
        width: computed.width,
        height: computed.height,
        rectWidth: Number(rect.width.toFixed(2)),
        rectHeight: Number(rect.height.toFixed(2)),
      };
    };
    const initial = snapshot('media-mismatch');
    style.media = 'all';
    const mediaEnabled = snapshot('media-all');
    style.sheet.disabled = true;
    const sheetDisabled = snapshot('sheet-disabled');
    style.sheet.disabled = false;
    style.disabled = true;
    const elementDisabled = snapshot('style-element-disabled');
    style.disabled = false;
    const reenabled = snapshot('reenabled');
    return {initial, mediaEnabled, sheetDisabled, elementDisabled, reenabled};
  });
  assert.equal(media.initial.matchesQuery, false);
  assert.equal(media.mediaEnabled.color, 'rgb(99, 1, 2)');
  assert.equal(media.sheetDisabled.color, 'rgb(0, 0, 0)');
  assert.equal(media.reenabled.color, 'rgb(99, 1, 2)');
  const mediaCase = {
    caseId: 'media-and-disabled-stylesheets',
    source: 'Inline style media mismatch/all and HTMLStyleElement.disabled/CSSStyleSheet.disabled toggles, with actual computed color and layout measurements.',
    result: media,
  };

  const linkPage = await makePage(context, 'dynamic-link-lifecycle');
  ownedPages.add(linkPage);
  await linkPage.evaluate(() => { window.__stylesheetEvents = []; window.__stylesheetLinks = {}; });
  const linkFirst = await appendLinkAndWait(linkPage, 'switch-link', originA + '/css/link-a.css?case=dynamic-a');
  const linkFirstStyle = await styleSnapshot(linkPage, 'linkProbe');
  const linkHrefChangeBefore = await linkPage.evaluate(() => ({
    eventCount: window.__stylesheetEvents.length,
    href: window.__stylesheetLinks['switch-link'].href,
    sheetHref: window.__stylesheetLinks['switch-link'].sheet?.href ?? null,
  }));
  const secondExpectedCount = linkHrefChangeBefore.eventCount + 1;
  await linkPage.evaluate(({href}) => { window.__stylesheetLinks['switch-link'].href = href; }, {
    href: originA + '/css/link-b.css?case=dynamic-b',
  });
  await linkPage.waitForFunction(count => window.__stylesheetEvents.length >= count, secondExpectedCount, {timeout: 5000});
  const linkAfterHrefChange = await linkPage.evaluate(() => ({
    events: window.__stylesheetEvents.slice(),
    link: (() => {
      const link = window.__stylesheetLinks['switch-link'];
      let rules = null;
      try { rules = Array.from(link.sheet?.cssRules ?? [], rule => rule.cssText); } catch {}
      return {hrefAttribute: link.getAttribute('href'), href: link.href, sheetPresent: link.sheet != null,
        sheetHref: link.sheet?.href ?? null, cssRules: rules};
    })(),
  }));
  const linkSecondStyle = await styleSnapshot(linkPage, 'linkProbe');
  const removedLink = await linkPage.evaluate(() => {
    const link = window.__stylesheetLinks['switch-link'];
    link.remove();
    const target = document.querySelector('#linkProbe');
    const computed = getComputedStyle(target);
    const rect = target.getBoundingClientRect();
    return {
      sheetPresentAfterRemove: link.sheet != null,
      eventCount: window.__stylesheetEvents.length,
      style: {color: computed.color, width: computed.width, height: computed.height,
        rectWidth: Number(rect.width.toFixed(2)), rectHeight: Number(rect.height.toFixed(2))},
      styleSheets: Array.from(document.styleSheets, sheet => sheet.href),
    };
  });
  const readdExpectedCount = removedLink.eventCount + 1;
  await linkPage.evaluate(() => document.head.append(window.__stylesheetLinks['switch-link']));
  await linkPage.waitForFunction(count => window.__stylesheetEvents.length >= count, readdExpectedCount, {timeout: 5000});
  const readdedLink = await linkPage.evaluate(() => ({
    events: window.__stylesheetEvents.slice(),
    href: window.__stylesheetLinks['switch-link'].href,
    sheetHref: window.__stylesheetLinks['switch-link'].sheet?.href ?? null,
    styleSheets: Array.from(document.styleSheets, sheet => sheet.href),
  }));
  const linkReaddedStyle = await styleSnapshot(linkPage, 'linkProbe');
  const missingLink = await appendLinkAndWait(linkPage, 'missing-link', originA + '/css/missing.css?case=dynamic-missing');
  const linkCase = {
    caseId: 'dynamic-link-lifecycle-and-errors',
    source: 'A dynamic link stylesheet loads, changes href to another real stylesheet, is removed and re-added, and a 404 link reports its actual error event. The fixture records event timing, sheet state, CSSOM, computed color/size, and real request receipts.',
    linkFirst,
    linkFirstStyle,
    linkHrefChangeBefore,
    linkAfterHrefChange,
    linkSecondStyle,
    removedLink,
    readdedLink,
    linkReaddedStyle,
    missingLink,
  };
  assert.equal(linkFirst.events[0].type, 'load');
  assert.equal(linkFirstStyle.color, 'rgb(201, 0, 0)');
  assert.equal(linkSecondStyle.color, 'rgb(0, 201, 0)');
  assert.equal(removedLink.sheetPresentAfterRemove, false);
  assert.equal(removedLink.style.color, 'rgb(0, 0, 0)');
  assert.equal(linkReaddedStyle.color, 'rgb(0, 201, 0)');
  assert.equal(missingLink.events[0].type, 'error');

  const basePage = await makePage(context, 'base-href-effects');
  ownedPages.add(basePage);
  await basePage.evaluate(({origin}) => {
    const base = document.createElement('base');
    base.id = 'dynamic-base';
    base.href = origin + '/base/one/';
    document.head.append(base);
    window.__baseEvents = [];
  }, {origin: originA});
  const baseFirst = await appendLinkAndWait(basePage, 'base-existing-link', 'styles.css?case=base-existing');
  const baseFirstStyle = await styleSnapshot(basePage, 'baseProbe');
  const existingBeforeBaseChange = await basePage.evaluate(() => {
    const link = window.__stylesheetLinks['base-existing-link'];
    return {baseHref: document.querySelector('#dynamic-base').href,
      linkAttribute: link.getAttribute('href'), href: link.href, sheetHref: link.sheet?.href ?? null,
      styleSheets: Array.from(document.styleSheets, sheet => sheet.href)};
  });
  const requestCountBeforeBaseChange = serverRequests.length;
  await basePage.evaluate(() => {
    const base = document.querySelector('#dynamic-base');
    base.href = location.origin + '/base/two/';
  });
  await sleep(180);
  const existingAfterBaseChange = await basePage.evaluate(() => {
    const link = window.__stylesheetLinks['base-existing-link'];
    const computed = getComputedStyle(document.querySelector('#baseProbe'));
    const rect = document.querySelector('#baseProbe').getBoundingClientRect();
    return {baseHref: document.querySelector('#dynamic-base').href,
      linkAttribute: link.getAttribute('href'), href: link.href, sheetHref: link.sheet?.href ?? null,
      color: computed.color, width: computed.width,
      rectWidth: Number(rect.width.toFixed(2)), rectHeight: Number(rect.height.toFixed(2)),
      eventCount: window.__stylesheetEvents.length,
      styleSheets: Array.from(document.styleSheets, sheet => sheet.href)};
  });
  const requestCountAfterBaseChange = serverRequests.length;
  const baseNewLink = await appendLinkAndWait(basePage, 'base-new-link', 'styles.css?case=base-new');
  const baseNewStyle = await styleSnapshot(basePage, 'baseProbe');
  const baseCase = {
    caseId: 'base-href-existing-and-new-links',
    source: 'An existing relative stylesheet link is loaded under /base/one/, then the document base href changes to /base/two/. The existing link property/sheet and request count are observed before a newly inserted relative link resolves and loads.',
    initialLink: baseFirst,
    initialStyle: baseFirstStyle,
    existingBeforeBaseChange,
    existingAfterBaseChange,
    requestCountBeforeBaseChange,
    requestCountAfterBaseChange,
    existingLinkTriggeredRequestOnBaseChange: requestCountAfterBaseChange > requestCountBeforeBaseChange,
    newLink: baseNewLink,
    newLinkStyle: baseNewStyle,
  };
  assert.equal(baseFirst.events[0].type, 'load');
  assert.equal(baseFirstStyle.color, 'rgb(145, 0, 0)');
  assert.equal(baseNewLink.events[0].type, 'load');
  assert.equal(baseNewStyle.color, 'rgb(0, 0, 145)');

  const importPage = await makePage(context, 'import-relative-resource-and-order');
  ownedPages.add(importPage);
  await importPage.evaluate(() => { window.__stylesheetEvents = []; window.__stylesheetLinks = {}; });
  const importStart = await importPage.evaluate(() => performance.now());
  const primaryLink = await appendLinkAndWait(importPage, 'primary-import-link', originA + '/css/primary.css?case=primary-sheet');
  await importPage.waitForFunction(() => performance.getEntriesByType('resource')
    .some(entry => entry.name.includes('css-relative-asset')), null, {timeout: 5000});
  const importSnapshot = await importPage.evaluate(() => {
    const link = window.__stylesheetLinks['primary-import-link'];
    const importRule = link.sheet.cssRules[0];
    const importedSheet = importRule.styleSheet;
    const resources = performance.getEntriesByType('resource')
      .filter(entry => entry.name.includes('/css/primary.css') || entry.name.includes('/css/imported.css') || entry.name.includes('css-relative-asset'))
      .map(entry => ({name: entry.name, initiatorType: entry.initiatorType,
        startTime: Number(entry.startTime.toFixed(2)), responseEnd: Number(entry.responseEnd.toFixed(2)),
        duration: Number(entry.duration.toFixed(2))}));
    const computedFor = id => {
      const element = document.getElementById(id);
      const style = getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      return {color: style.color, backgroundImage: style.backgroundImage, width: style.width, height: style.height,
        rectWidth: Number(rect.width.toFixed(2)), rectHeight: Number(rect.height.toFixed(2))};
    };
    return {
      href: link.href,
      sheetHref: link.sheet.href,
      loadEvents: window.__stylesheetEvents,
      loadElapsedMs: window.__stylesheetEvents[0]?.elapsedMs ?? null,
      cssRules: Array.from(link.sheet.cssRules, rule => rule.cssText),
      import: {href: importRule.href, cssText: importRule.cssText, sheetPresent: importedSheet != null,
        rules: importedSheet ? Array.from(importedSheet.cssRules, rule => rule.cssText) : []},
      resources,
      targets: {external: computedFor('externalProbe'), imported: computedFor('importProbe'), order: computedFor('orderProbe')},
      styleSheetsBeforeCascadeAppend: Array.from(document.styleSheets, sheet => sheet.href),
    };
  });
  const orderLater = await appendLinkAndWait(importPage, 'later-order-link', originA + '/css/order-later.css?case=stylesheet-order-later');
  const cascadeAfterLater = {
    target: await styleSnapshot(importPage, 'orderProbe'),
    styleSheets: await importPage.evaluate(() => Array.from(document.styleSheets, sheet => sheet.href)),
  };
  await importPage.evaluate(() => window.__stylesheetLinks['later-order-link'].remove());
  const cascadeAfterRemove = await styleSnapshot(importPage, 'orderProbe');
  const importCase = {
    caseId: 'import-completion-relative-assets-and-order',
    source: 'A same-origin external stylesheet uses a delayed @import, a relative SVG background URL, and equal-specificity cascade rules. A later link overrides the cascade and removing it reveals the earlier rule. CSSOM, Resource Timing, computed geometry, event timing, and actual request sequence are captured.',
    link: primaryLink,
    snapshot: importSnapshot,
    laterOrderLink: orderLater,
    cascadeAfterLater,
    cascadeAfterRemove,
    importStartedAtPerformanceMs: Number(importStart.toFixed(2)),
  };
  assert.equal(primaryLink.events[0].type, 'load');
  assert.ok(importSnapshot.import.sheetPresent, 'The imported CSSStyleSheet must be available after the parent load event');
  assert.ok(importSnapshot.resources.some(entry => entry.name.includes('/css/imported.css')));
  assert.ok(importSnapshot.resources.some(entry => entry.name.includes('css-relative-asset')));
  assert.ok(importSnapshot.resources.find(entry => entry.name.includes('/css/imported.css')).responseEnd <= importSnapshot.loadElapsedMs);
  assert.equal(importSnapshot.targets.external.color, 'rgb(7, 8, 9)');
  assert.equal(importSnapshot.targets.external.width, '35px');
  assert.equal(importSnapshot.targets.imported.height, '43px');
  assert.equal(importSnapshot.targets.order.color, 'rgb(200, 0, 0)');
  assert.equal(cascadeAfterLater.target.color, 'rgb(0, 170, 0)');
  assert.equal(cascadeAfterRemove.color, 'rgb(200, 0, 0)');

  const crossPage = await makePage(context, 'cross-origin-css-rules');
  ownedPages.add(crossPage);
  await crossPage.evaluate(() => { window.__stylesheetEvents = []; window.__stylesheetLinks = {}; });
  const crossLink = await appendLinkAndWait(crossPage, 'opaque-cross-link', originB + '/css/cross.css?case=css-cross-no-cors');
  const crossStyle = await styleSnapshot(crossPage, 'crossProbe');
  const corsLink = await appendLinkAndWait(crossPage, 'cors-cross-link', originB + '/css/cors.css?case=css-cross-cors', {crossOrigin: 'anonymous'});
  const corsStyle = await styleSnapshot(crossPage, 'corsProbe');
  const crossCase = {
    caseId: 'cross-origin-cssom-and-cors',
    source: 'A cross-origin stylesheet without crossorigin applies but cssRules access is attempted; a second link uses crossorigin=anonymous and ACAO:* so its rules can be read. Actual computed styles and request Origin/Referer are retained.',
    opaqueLink: crossLink,
    opaqueComputedStyle: crossStyle,
    corsLink,
    corsComputedStyle: corsStyle,
  };
  assert.equal(crossLink.events[0].type, 'load');
  assert.equal(crossStyle.color, 'rgb(44, 55, 66)');
  assert.equal(crossLink.link.cssRulesError?.name, 'SecurityError');
  assert.equal(corsLink.events[0].type, 'load');
  assert.equal(corsStyle.color, 'rgb(66, 55, 44)');
  assert.equal(corsLink.link.cssRulesError, null);

  const extensionStartServerRequestCount = serverRequests.length;
  const extensionStartPageRequestCount = pageRequests.length;

  const pendingLinkPage = await makePage(context, 'link-href-swap-pending');
  ownedPages.add(pendingLinkPage);
  await pendingLinkPage.evaluate(() => { window.__stylesheetEvents = []; window.__stylesheetLinks = {}; });
  const pendingLinkInitial = await appendLinkAndWait(
    pendingLinkPage,
    'slow-switch-link',
    originA + '/css/link-a.css?case=slow-switch-initial',
  );
  await pendingLinkPage.evaluate(() => {
    window.__slowLinkInitialSheet = window.__stylesheetLinks['slow-switch-link'].sheet;
  });
  const pendingEventCountBeforeSwap = await pendingLinkPage.evaluate(() => window.__stylesheetEvents.length);
  await pendingLinkPage.evaluate(({href}) => {
    window.__stylesheetLinks['slow-switch-link'].href = href;
  }, {href: originA + '/css/link-slow.css?case=slow-switch-response'});
  const slowRequestReceived = await waitUntil(() => serverRequests.some(request =>
    request.path === '/css/link-slow.css?case=slow-switch-response'), 1500);
  if (slowRequestReceived) await sleep(25);
  const whileSlowResponsePending = await pendingLinkPage.evaluate(() => {
    const link = window.__stylesheetLinks['slow-switch-link'];
    const target = document.querySelector('#linkProbe');
    const computed = getComputedStyle(target);
    const rect = target.getBoundingClientRect();
    let cssRules = null;
    try { cssRules = Array.from(link.sheet?.cssRules ?? [], rule => rule.cssText); } catch {}
    return {
      eventCount: window.__stylesheetEvents.length,
      href: link.href,
      sheetPresent: link.sheet != null,
      sheetHref: link.sheet?.href ?? null,
      sameSheetAsBeforeSwap: link.sheet === window.__slowLinkInitialSheet,
      cssRules,
      computed: {color: computed.color, width: computed.width, height: computed.height,
        rectWidth: Number(rect.width.toFixed(2)), rectHeight: Number(rect.height.toFixed(2))},
    };
  });
  const slowLoadSeen = await waitUntil(async () =>
    await pendingLinkPage.evaluate(count => window.__stylesheetEvents.length >= count, pendingEventCountBeforeSwap + 1), 5000);
  const afterSlowResponse = await pendingLinkPage.evaluate(() => {
    const link = window.__stylesheetLinks['slow-switch-link'];
    const target = document.querySelector('#linkProbe');
    const computed = getComputedStyle(target);
    const rect = target.getBoundingClientRect();
    let cssRules = null;
    try { cssRules = Array.from(link.sheet?.cssRules ?? [], rule => rule.cssText); } catch {}
    return {
      events: window.__stylesheetEvents,
      href: link.href,
      sheetPresent: link.sheet != null,
      sheetHref: link.sheet?.href ?? null,
      sameSheetAsBeforeSwap: link.sheet === window.__slowLinkInitialSheet,
      cssRules,
      computed: {color: computed.color, width: computed.width, height: computed.height,
        rectWidth: Number(rect.width.toFixed(2)), rectHeight: Number(rect.height.toFixed(2))},
    };
  });
  const pendingHrefChangeCase = {
    caseId: 'link-href-change-pending-state',
    source: 'After a same-origin link stylesheet has loaded, change href to a 450 ms synthetic CSS response. Capture link.sheet, CSSOM, load-event count, and computed style while the request is in flight and after the new sheet completes.',
    initial: pendingLinkInitial,
    plannedServerDelayMs: 450,
    slowRequestReceived,
    whileSlowResponsePending,
    slowLoadSeen,
    afterSlowResponse,
  };
  assert.equal(pendingLinkInitial.events[0].type, 'load');
  assert.ok(slowRequestReceived);
  assert.ok(slowLoadSeen);

  async function captureFailedImport(pageCase, linkId, rootPath, rootCase) {
    const page = await makePage(context, pageCase);
    ownedPages.add(page);
    await page.evaluate(() => { window.__stylesheetEvents = []; window.__stylesheetLinks = {}; });
    const requestStart = serverRequests.length;
    const rootLink = await appendLinkAndWait(page, linkId, originA + rootPath + '?case=' + rootCase);
    const computed = await styleSnapshot(page, 'importProbe');
    const cssom = await page.evaluate(id => {
      const link = window.__stylesheetLinks[id];
      const rules = Array.from(link.sheet?.cssRules ?? [], rule => rule.cssText);
      const importRule = link.sheet?.cssRules[0];
      const importedSheet = importRule?.styleSheet ?? null;
      let importedRules = null;
      try { importedRules = importedSheet ? Array.from(importedSheet.cssRules, rule => rule.cssText) : null; } catch {}
      return {
        sheetPresent: link.sheet != null,
        sheetHref: link.sheet?.href ?? null,
        rootRules: rules,
        importHref: importRule?.href ?? null,
        importedSheetPresent: importedSheet != null,
        importedRules,
      };
    }, linkId);
    return {
      rootLink,
      computed,
      cssom,
      requests: serverRequests.slice(requestStart),
    };
  }
  const failedImport404 = await captureFailedImport(
    'import-failure-404', 'failed-import-404-link', '/css/root-import-fail-404.css', 'import-fail-root-404');
  const failedImportMime = await captureFailedImport(
    'import-failure-mime', 'failed-import-mime-link', '/css/root-import-fail-mime.css', 'import-fail-root-mime');
  const failedImportsCase = {
    caseId: 'successful-root-with-failed-imports',
    source: 'A valid root stylesheet imports one 404 resource and one 200 text/plain resource. Record each owner link load/error event, import CSSOM state, root declaration computed style, and actual response status/content type.',
    failedImport404,
    failedImportMime,
  };
  assert.equal(failedImport404.computed.color, 'rgb(120, 0, 0)');
  assert.equal(failedImportMime.computed.color, 'rgb(120, 0, 0)');
  assert.ok(failedImport404.requests.some(request => request.path.startsWith('/css/import-fail-404.css')));
  assert.ok(failedImportMime.requests.some(request => request.path.startsWith('/css/import-fail-mime.css')));

  const inlineStyleEventPage = await makePage(context, 'inline-style-load-events');
  ownedPages.add(inlineStyleEventPage);
  const inlineStyleEventObservations = await inlineStyleEventPage.evaluate(async origin => {
    const style = document.createElement('style');
    style.id = 'inline-style-event-probe';
    const events = [];
    let phase = 'initial-no-import';
    style.addEventListener('load', event => events.push({type: event.type, phase, elapsedMs: Number(performance.now().toFixed(2)), sheetHref: style.sheet?.href ?? null}));
    style.addEventListener('error', event => events.push({type: event.type, phase, elapsedMs: Number(performance.now().toFixed(2)), sheetHref: style.sheet?.href ?? null}));
    const wait = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
    const snapshot = label => {
      const target = document.querySelector('#importProbe');
      const computed = getComputedStyle(target);
      const rect = target.getBoundingClientRect();
      let rules = null;
      try { rules = Array.from(style.sheet?.cssRules ?? [], rule => rule.cssText); } catch {}
      return {label, phase, eventCount: events.length, color: computed.color, width: computed.width,
        height: computed.height, rectWidth: Number(rect.width.toFixed(2)), rectHeight: Number(rect.height.toFixed(2)),
        sheetPresent: style.sheet != null, sheetHref: style.sheet?.href ?? null, cssRules: rules};
    };
    style.textContent = '#importProbe { color: rgb(1, 1, 1); width: 20px; height: 12px; }';
    document.head.append(style);
    await wait(90);
    const initialWithoutImport = snapshot('initial-no-import');
    phase = 'textContent-no-import';
    style.textContent = '#importProbe { color: rgb(2, 2, 2); width: 21px; height: 13px; }';
    await wait(70);
    const afterTextContentWithoutImport = snapshot('textContent-no-import');
    phase = 'insertRule-no-import';
    style.sheet.insertRule('#importProbe { color: rgb(3, 3, 3); height: 14px; }', style.sheet.cssRules.length);
    await wait(70);
    const afterInsertRuleWithoutImport = snapshot('insertRule-no-import');
    phase = 'textContent-with-import';
    style.textContent = `@import url('${origin}/css/inline-style-import.css?case=inline-style-import');\n#importProbe { color: rgb(4, 4, 4); width: 23px; }`;
    await wait(330);
    const withImport = snapshot('import-settled');
    const importRule = style.sheet?.cssRules[0];
    const importedSheet = importRule?.styleSheet ?? null;
    let importedRules = null;
    try { importedRules = importedSheet ? Array.from(importedSheet.cssRules, rule => rule.cssText) : null; } catch {}
    const resources = performance.getEntriesByType('resource')
      .filter(entry => entry.name.includes('inline-style-import'))
      .map(entry => ({name: entry.name, initiatorType: entry.initiatorType,
        startTime: Number(entry.startTime.toFixed(2)), responseEnd: Number(entry.responseEnd.toFixed(2))}));
    phase = 'insertRule-with-import';
    style.sheet.insertRule('#importProbe { color: rgb(7, 7, 7); }', style.sheet.cssRules.length);
    await wait(70);
    const afterInsertRuleWithImport = snapshot('insertRule-with-import');
    phase = 'textContent-after-import';
    style.textContent = '#importProbe { color: rgb(5, 5, 5); width: 24px; height: 18px; }';
    await wait(70);
    const afterTextContentFollowingImport = snapshot('textContent-after-import');
    phase = 'insertRule-after-import';
    style.sheet.insertRule('#importProbe { color: rgb(6, 6, 6); }', style.sheet.cssRules.length);
    await wait(70);
    const afterInsertRuleFollowingImport = snapshot('insertRule-after-import');
    return {
      eventRecords: events,
      stages: {initialWithoutImport, afterTextContentWithoutImport, afterInsertRuleWithoutImport,
        withImport, afterInsertRuleWithImport, afterTextContentFollowingImport, afterInsertRuleFollowingImport},
      importHref: importRule?.href ?? null,
      importedSheetPresent: importedSheet != null,
      importedRules,
      resources,
    };
  }, originA);
  const inlineStyleEventsCase = {
    caseId: 'inline-style-load-event-behavior',
    source: 'Observe load/error listeners on a dynamically inserted inline style with no import, after textContent and insertRule mutations, after an imported stylesheet finishes, and after further mutations.',
    result: inlineStyleEventObservations,
  };
  assert.ok(serverRequests.some(request => request.path === '/css/inline-style-import.css?case=inline-style-import'));

  const disabledLinkPage = await makePage(context, 'disabled-link-fetch');
  ownedPages.add(disabledLinkPage);
  await disabledLinkPage.evaluate(href => {
    window.__stylesheetEvents = [];
    window.__stylesheetLinks = {};
    const link = document.createElement('link');
    link.id = 'disabled-link-probe';
    link.rel = 'stylesheet';
    link.disabled = true;
    link.addEventListener('load', () => window.__stylesheetEvents.push({type: 'load', elapsedMs: Number(performance.now().toFixed(2)), href: link.href}));
    link.addEventListener('error', () => window.__stylesheetEvents.push({type: 'error', elapsedMs: Number(performance.now().toFixed(2)), href: link.href}));
    link.href = href;
    document.head.append(link);
    window.__stylesheetLinks['disabled-link-probe'] = link;
  }, originA + '/css/disabled-link.css?case=disabled-link');
  await sleep(230);
  const disabledRequestCountBeforeEnable = serverRequests.filter(request => request.path === '/css/disabled-link.css?case=disabled-link').length;
  const disabledLinkBeforeEnable = await disabledLinkPage.evaluate(() => {
    const link = window.__stylesheetLinks['disabled-link-probe'];
    const target = document.querySelector('#linkProbe');
    const computed = getComputedStyle(target);
    const rect = target.getBoundingClientRect();
    let rules = null;
    try { rules = Array.from(link.sheet?.cssRules ?? [], rule => rule.cssText); } catch {}
    return {disabled: link.disabled, href: link.href, sheetPresent: link.sheet != null,
      sheetHref: link.sheet?.href ?? null, cssRules: rules, events: window.__stylesheetEvents,
      computed: {color: computed.color, width: computed.width, height: computed.height,
        rectWidth: Number(rect.width.toFixed(2)), rectHeight: Number(rect.height.toFixed(2))}};
  });
  await disabledLinkPage.evaluate(() => { window.__stylesheetLinks['disabled-link-probe'].disabled = false; });
  const enabledRequestSeen = await waitUntil(() => serverRequests.some(request =>
    request.path === '/css/disabled-link.css?case=disabled-link'), 700);
  await sleep(220);
  const disabledLinkAfterEnable = await disabledLinkPage.evaluate(() => {
    const link = window.__stylesheetLinks['disabled-link-probe'];
    const target = document.querySelector('#linkProbe');
    const computed = getComputedStyle(target);
    const rect = target.getBoundingClientRect();
    return {disabled: link.disabled, href: link.href, sheetPresent: link.sheet != null,
      sheetHref: link.sheet?.href ?? null, events: window.__stylesheetEvents,
      computed: {color: computed.color, width: computed.width, height: computed.height,
        rectWidth: Number(rect.width.toFixed(2)), rectHeight: Number(rect.height.toFixed(2))}};
  });
  const requestCountAfterEnable = serverRequests.filter(request => request.path === '/css/disabled-link.css?case=disabled-link').length;
  await disabledLinkPage.evaluate(() => { window.__stylesheetLinks['disabled-link-probe'].disabled = true; });
  const disabledLinkAfterLoadDisabled = await styleSnapshot(disabledLinkPage, 'linkProbe');
  await disabledLinkPage.evaluate(() => { window.__stylesheetLinks['disabled-link-probe'].disabled = false; });
  await sleep(230);
  const disabledLinkAfterReenable = await disabledLinkPage.evaluate(() => {
    const link = window.__stylesheetLinks['disabled-link-probe'];
    const target = document.querySelector('#linkProbe');
    const computed = getComputedStyle(target);
    const rect = target.getBoundingClientRect();
    return {disabled: link.disabled, href: link.href, sheetPresent: link.sheet != null,
      sheetHref: link.sheet?.href ?? null, events: window.__stylesheetEvents,
      computed: {color: computed.color, width: computed.width, height: computed.height,
        rectWidth: Number(rect.width.toFixed(2)), rectHeight: Number(rect.height.toFixed(2))}};
  });
  const requestCountAfterReenable = serverRequests.filter(request => request.path === '/css/disabled-link.css?case=disabled-link').length;
  const disabledLinkCase = {
    caseId: 'disabled-link-fetch-and-reenable',
    source: 'Insert a disabled link with href, observe fetch/sheet/events/computed style, enable it, then disable and re-enable the successfully loaded link while counting actual requests.',
    disabledRequestCountBeforeEnable,
    disabledLinkBeforeEnable,
    enabledRequestSeen,
    disabledLinkAfterEnable,
    requestCountAfterEnable,
    disabledLinkAfterLoadDisabled,
    disabledLinkAfterReenable,
    requestCountAfterReenable,
  };

  const commandPages = await Promise.all([...ownedPages].map(page => page.close().catch(() => {})));
  void commandPages;
  const runnerBytes = await readFile(fileURLToPath(import.meta.url));
  const unexpectedPageRequests = pageRequests.filter(item => !isSyntheticLoopbackUrl(item.url));
  assert.equal(unexpectedPageRequests.length, 0, 'All page requests must remain on the two synthetic loopback hosts');
  assert.equal(blockedPageRequests.length, 0, 'No non-loopback page request was allowed through Playwright routing');
  assert.ok(serverRequests.length > 0);
  assert.ok(serverRequests.every(item => item.hostname === '127.0.0.1' || item.hostname === 'localhost'));
  assert.ok(serverRequests.every(item => !item.authorizationPresent));

  const blockedCountsByMethod = blockedProxyRequests.reduce((counts, request) => {
    counts[request.method] = (counts[request.method] ?? 0) + 1;
    return counts;
  }, {});
  const currentBaseCases = [cssomCase, mediaCase, linkCase, baseCase, importCase, crossCase];
  const frozenBaseCaseIds = currentBaseCases.map(item => item.caseId);
  const priorBaseCaseMap = new Map((priorFixture?.cases ?? []).map(item => [item.caseId, item]));
  const frozenBaseCases = frozenBaseCaseIds.every(caseId => priorBaseCaseMap.has(caseId))
    ? frozenBaseCaseIds.map(caseId => priorBaseCaseMap.get(caseId))
    : currentBaseCases;
  const currentExtensionCases = [pendingHrefChangeCase, failedImportsCase, inlineStyleEventsCase, disabledLinkCase];
  const priorBaseServerRequests = priorFixture?.serverRequests?.length >= 18
    ? priorFixture.serverRequests.slice(0, 18)
    : normalize(serverRequests.slice(0, extensionStartServerRequestCount), actualPort, proxyPort);
  const priorBasePageRequests = priorFixture?.pageRequests?.length >= 18
    ? priorFixture.pageRequests.slice(0, 18)
    : normalize(pageRequests.slice(0, extensionStartPageRequestCount), actualPort, proxyPort);
  const capturedExtensionServerRequests = normalize(
    serverRequests.slice(extensionStartServerRequestCount), actualPort, proxyPort);
  const capturedExtensionPageRequests = normalize(
    pageRequests.slice(extensionStartPageRequestCount), actualPort, proxyPort);
  const priorProxyBlockedCount = priorFixture?.externalProxy?.blockedRequestCount ?? 0;
  const priorBlockedCountsByMethod = priorFixture?.externalProxy?.blockedCountsByMethod ?? {};
  const combinedBlockedCountsByMethod = {...priorBlockedCountsByMethod};
  for (const [method, count] of Object.entries(blockedCountsByMethod)) {
    combinedBlockedCountsByMethod[method] = (combinedBlockedCountsByMethod[method] ?? 0) + count;
  }
  const runnerSha256 = createHash('sha256').update(runnerBytes).digest('hex');
  const rawFixture = {
    browserVersion: browser.version(),
    browserProduct: 'Playwright chromium-headless-shell dedicated test browser',
    browserExecutable,
    runner: 'apps/android/tool/parity/verify_document_stylesheets_browser.mjs',
    runnerSha256,
    captureProvenance: {
      frozenOriginalSixCasesRunnerSha256: priorFixture?.captureProvenance?.frozenOriginalSixCasesRunnerSha256
        ?? priorFixture?.runnerSha256 ?? runnerSha256,
      appendedFourCasesRunnerSha256: runnerSha256,
    },
    browserFlags: {
      hostResolverRules: 'MAP localhost 127.0.0.1',
      backgroundNetworkingDisabled: true,
      nonForwardingLoopbackProxyConfigured: true,
      proxyForwardsRequests: false,
      pageRequestsRestrictedToSyntheticLoopback: true,
    },
    origins: {
      a: fixtureOrigins.a,
      b: fixtureOrigins.b,
      relation: 'Same ephemeral port but distinct hosts/origins: 127.0.0.1 and localhost. localhost is explicitly resolved to 127.0.0.1. The second origin is used only for cross-origin stylesheet/CORS behavior.',
    },
    caseCount: frozenBaseCases.length + currentExtensionCases.length,
    cases: [...frozenBaseCases, ...currentExtensionCases],
    serverRequests: [...priorBaseServerRequests, ...capturedExtensionServerRequests],
    pageRequests: [...priorBasePageRequests, ...capturedExtensionPageRequests],
    externalProxy: {
      origin: 'http://127.0.0.1:43199',
      forwardsRequests: false,
      blockedRequestCount: priorProxyBlockedCount + blockedProxyRequests.length,
      blockedCountsByMethod: combinedBlockedCountsByMethod,
      nonLoopbackPageRequestCount: unexpectedPageRequests.length,
      nonLoopbackPageRequests: unexpectedPageRequests,
    },
    scope: {
      tested: 'Inline CSSOM insertRule/deleteRule and CSSStyleDeclaration.setProperty; replacing style.textContent; style media and disabled toggles; dynamic link insert/href change/remove/readd and 404 error; old-sheet state while a replacement href is pending; root stylesheet success with imported 404 and wrong-MIME responses; inline style load/error events across creation, textContent, CSSOM, and @import; disabled-link fetch, enable, disable, and re-enable; existing/new relative links after base href change; delayed @import load completion; CSS-relative SVG resource URL; stylesheet cascade order; cross-origin cssRules SecurityError versus CORS-enabled access; computed colors and layout sizes.',
      notTested: 'AdoptedStyleSheets, constructable stylesheets, CSS modules, shadow-root stylesheet scoping, import maps, unusual CSS parser edge cases, CSP, integrity/crossorigin credentials modes, TLS, and filesystem origins.',
      transport: 'The Node server binds only to 127.0.0.1. Chrome Headless Shell 153 uses only the synthetic 127.0.0.1/localhost origins. The configured loopback proxy never forwards. Playwright request routing aborts any other page request; background attempts are counted as locally blocked proxy requests.',
    },
  };
  const fixture = normalize(rawFixture, actualPort, proxyPort);
  await writeFile(fixturePath, JSON.stringify(fixture, null, 2) + '\n');
  const fixtureBytes = await readFile(fixturePath);
  process.stdout.write(JSON.stringify({
    browserVersion: fixture.browserVersion,
    browserExecutable: fixture.browserExecutable,
    fixturePath,
    runnerSha256: fixture.runnerSha256,
    fixtureSha256: createHash('sha256').update(fixtureBytes).digest('hex'),
    caseCount: fixture.caseCount,
    preservedOriginalCaseCount: frozenBaseCases.length,
    appendedCaseCount: currentExtensionCases.length,
    appendedRequestCount: capturedExtensionServerRequests.length,
    serverRequestCount: fixture.serverRequests.length,
    pageRequestCount: fixture.pageRequests.length,
    blockedBackgroundRequestCount: fixture.externalProxy.blockedRequestCount,
    authorizationPresentCount: fixture.serverRequests.filter(item => item.authorizationPresent).length,
    cases: fixture.cases.map(item => item.caseId),
    cssom: {insert: cssom.afterInsert.target, setProperty: cssom.afterSetProperty.target,
      textContent: cssom.afterTextReset.target, sameSheetAfterReset: cssom.afterTextReset.sameSheetObject},
    links: {first: linkFirstStyle.color, afterHrefChange: linkSecondStyle.color,
      afterRemove: removedLink.style.color, afterReadd: linkReaddedStyle.color, error: missingLink.events[0].type},
    base: {existingHrefBefore: existingBeforeBaseChange.href, existingHrefAfter: existingAfterBaseChange.href,
      existingSheetAfter: existingAfterBaseChange.sheetHref, newLinkSheet: baseNewLink.link.sheetHref,
      requestsOnBaseChange: requestCountAfterBaseChange - requestCountBeforeBaseChange},
    import: {loadMs: importSnapshot.loadElapsedMs, resources: importSnapshot.resources,
      external: importSnapshot.targets.external, imported: importSnapshot.targets.imported,
      orderBeforeLater: importSnapshot.targets.order.color, orderAfterLater: cascadeAfterLater.target.color,
      orderAfterRemove: cascadeAfterRemove.color},
    crossOrigin: {noCorsRulesError: crossLink.link.cssRulesError?.name ?? null,
      corsRulesError: corsLink.link.cssRulesError?.name ?? null,
      noCorsColor: crossStyle.color, corsColor: corsStyle.color},
    pendingHref: {before: whileSlowResponsePending, after: afterSlowResponse},
    failedImports: {
      import404OwnerEvent: failedImport404.rootLink.events[0]?.type ?? null,
      import404RootColor: failedImport404.computed.color,
      import404Response: failedImport404.requests.find(request => request.path.startsWith('/css/import-fail-404.css'))?.responseStatus ?? null,
      wrongMimeOwnerEvent: failedImportMime.rootLink.events[0]?.type ?? null,
      wrongMimeRootColor: failedImportMime.computed.color,
      wrongMimeResponseContentType: failedImportMime.requests.find(request => request.path.startsWith('/css/import-fail-mime.css'))?.responseContentType ?? null,
    },
    inlineStyleEvents: {eventRecords: inlineStyleEventObservations.eventRecords,
      eventCounts: Object.fromEntries(Object.entries(inlineStyleEventObservations.stages).map(([key, value]) => [key, value.eventCount])),
      importedRules: inlineStyleEventObservations.importedRules},
    disabledLink: {requestCountBeforeEnable: disabledRequestCountBeforeEnable,
      enabledRequestSeen, requestCountAfterEnable, requestCountAfterReenable,
      events: disabledLinkAfterReenable.events,
      colorBeforeEnable: disabledLinkBeforeEnable.computed.color,
      colorAfterEnable: disabledLinkAfterEnable.computed.color,
      colorAfterReenable: disabledLinkAfterReenable.computed.color},
  }, null, 2) + '\n');
} finally {
  if (context) await context.close().catch(() => {});
  if (browser) await browser.close().catch(() => {});
  await Promise.all([closeServer(server), closeServer(nonForwardingProxy)]);
}
